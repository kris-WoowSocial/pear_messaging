const express = require('express');
const redis = require('redis');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();

// Redis client for storing contact messages
const redisClient = redis.createClient({
  url: process.env.REDIS_URL || 'redis://localhost:6379'
});

redisClient.on('error', (err) => {
  console.error('Redis Client Error (contact):', err);
});

redisClient.connect().catch(console.error);

// Rate limiting: max 3 contact submissions per IP per 15 minutes
const rateLimiter = new Map();

const contactRateLimit = (req, res, next) => {
  const key = req.ip || req.connection.remoteAddress;
  const now = Date.now();
  const windowMs = 15 * 60 * 1000; // 15 minutes
  const maxRequests = 3;
  const windowStart = now - windowMs;

  const requests = (rateLimiter.get(key) || []).filter(t => t > windowStart);
  if (requests.length >= maxRequests) {
    return res.status(429).json({ error: 'Too many contact submissions. Please try again later.' });
  }

  requests.push(now);
  rateLimiter.set(key, requests);
  next();
};

/**
 * POST /api/contact
 * 
 * Submit a contact us message
 */
router.post('/', contactRateLimit, async (req, res) => {
  try {
    const { name, email, message } = req.body;

    // Validate required fields
    if (!name || !name.trim()) {
      return res.status(400).json({ error: 'Name is required' });
    }
    if (!email || !email.trim()) {
      return res.status(400).json({ error: 'Email is required' });
    }
    if (!message || !message.trim()) {
      return res.status(400).json({ error: 'Message is required' });
    }

    // Basic email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email.trim())) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    // Create contact message entry
    const contactId = uuidv4();
    const contactData = {
      id: contactId,
      name: name.trim(),
      email: email.trim(),
      message: message.trim(),
      createdAt: new Date().toISOString(),
      ip: req.ip || req.connection.remoteAddress,
    };

    // Store in Redis with 90-day TTL
    const redisKey = `contact:${contactId}`;
    await redisClient.setEx(redisKey, 90 * 24 * 60 * 60, JSON.stringify(contactData));

    // Also add to a list for easy retrieval
    await redisClient.lPush('contact:messages', contactId);

    console.log(`✅ Contact message received from ${email.trim()}`);

    res.status(201).json({ 
      success: true, 
      message: 'Contact message submitted successfully',
      id: contactId 
    });

  } catch (error) {
    console.error('❌ Contact submission error:', error);
    res.status(500).json({ error: 'Failed to submit contact message' });
  }
});

module.exports = router;
