const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 5000;

// Restrict CORS to same-origin in production, allow all in development
const corsOptions = {
  origin: process.env.NODE_ENV === 'production' ? false : '*',
};
app.use(cors(corsOptions));
app.use(express.json());

// Function to read secrets safely from mounted tmpfs volumes
function getSecret(secretKey, fallbackEnv) {
  const secretPath = path.join('/etc/secrets', secretKey);
  if (fs.existsSync(secretPath)) {
    try {
      return fs.readFileSync(secretPath, 'utf8').trim();
    } catch (err) {
      console.error(`Failed to read secret file at ${secretPath}:`, err.message);
    }
  }
  if (process.env[fallbackEnv]) {
    return process.env[fallbackEnv];
  }
  throw new Error(`CRITICAL: Secret '${secretKey}' could not be loaded from volume or environment!`);
}

// Retrieve DB Password from mounted secret volume (/etc/secrets/DB_PASSWORD)
const dbPassword = getSecret('DB_PASSWORD', 'DB_PASSWORD');

// PostgreSQL Pool Connection Setup
const pool = new Pool({
  host: process.env.DB_HOST || '172.16.20.2',
  port: process.env.DB_PORT || 5432,
  user: process.env.DB_USER || 'app_user',
  password: dbPassword,
  database: process.env.DB_NAME || 'ecommerce_db',
  connectionTimeoutMillis: 5000,
});

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ status: 'UP', database: 'connected' });
  } catch (err) {
    res.status(500).json({ status: 'DOWN', error: err.message });
  }
});

// GET /api/stress - CPU-intensive endpoint for HPA load testing
app.get('/api/stress', (req, res) => {
  const cycles = req.query.cycles ? parseInt(req.query.cycles, 10) : 10000000;
  let count = 0;

  // Synchronous CPU-blocking computation to trigger CPU utilization spikes for HPA
  for (let i = 0; i < cycles; i++) {
    count += Math.sqrt(i) * Math.sqrt(i);
  }

  res.json({ message: 'CPU stress calculation complete', cycles, count });
});

// GET /api/products - List all products
app.get('/api/products', async (req, res) => {
  try {
    const result = await pool.query('SELECT id, name, price, stock FROM products ORDER BY id ASC');
    res.json(result.rows);
  } catch (err) {
    console.error('Error fetching products:', err.message);
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// POST /api/orders - Place an order (reduces stock & records order)
app.post('/api/orders', async (req, res) => {
  const { productId, quantity } = req.body;

  if (!productId || !quantity || quantity <= 0) {
    return res.status(400).json({ error: 'Invalid product ID or quantity' });
  }

  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    // Check stock
    const productRes = await client.query('SELECT stock FROM products WHERE id = $1 FOR UPDATE', [productId]);
    if (productRes.rows.length === 0) {
      throw new Error('Product not found');
    }

    const currentStock = productRes.rows[0].stock;
    if (currentStock < quantity) {
      throw new Error('Insufficient stock available');
    }

    // Deduct stock
    await client.query('UPDATE products SET stock = stock - $1 WHERE id = $2', [quantity, productId]);

    // Create order record
    const orderRes = await client.query(
      'INSERT INTO orders (product_id, quantity) VALUES ($1, $2) RETURNING id, created_at',
      [productId, quantity]
    );

    await client.query('COMMIT');
    res.status(201).json({ message: 'Order placed successfully', order: orderRes.rows[0] });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ error: err.message });
  } finally {
    client.release();
  }
});

// Start server
const server = app.listen(PORT, () => {
  console.log(`Backend server running on port ${PORT}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM signal received: closing HTTP server...');
  server.close(() => {
    console.log('HTTP server closed.');
    pool.end(() => {
      console.log('PostgreSQL pool disconnected.');
      process.exit(0);
    });
  });
});