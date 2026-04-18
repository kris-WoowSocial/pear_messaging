const express = require('express');
const redis = require('redis');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();

// Redis client for storing reports
const redisClient = redis.createClient({
  url: process.env.REDIS_URL || 'redis://localhost:6379'
});

redisClient.on('error', (err) => {
  console.error('Redis Client Error (reports):', err);
});

redisClient.connect().catch(console.error);

// Rate limiting: max 5 reports per IP per 15 minutes
const rateLimiter = new Map();

const reportRateLimit = (req, res, next) => {
  const key = req.ip || req.connection.remoteAddress;
  const now = Date.now();
  const windowMs = 15 * 60 * 1000;
  const maxRequests = 5;
  const windowStart = now - windowMs;

  const requests = (rateLimiter.get(key) || []).filter(t => t > windowStart);
  if (requests.length >= maxRequests) {
    return res.status(429).json({ error: 'Too many reports. Please try again later.' });
  }

  requests.push(now);
  rateLimiter.set(key, requests);
  next();
};

/**
 * POST /api/reports
 * 
 * Submit a report for a user or message
 */
router.post('/', reportRateLimit, async (req, res) => {
  try {
    const { reporterDeviceId, targetType, targetId, reason, description } = req.body;

    // Validate required fields
    if (!reporterDeviceId) {
      return res.status(400).json({ error: 'Reporter device ID is required' });
    }
    if (!targetType) {
      return res.status(400).json({ error: 'Target type is required' });
    }
    if (!targetId) {
      return res.status(400).json({ error: 'Target ID is required' });
    }
    if (!reason) {
      return res.status(400).json({ error: 'Reason is required' });
    }

    // Create report entry
    const reportId = uuidv4();
    const reportData = {
      id: reportId,
      reporterDeviceId,
      targetType,
      targetId,
      reason,
      description: description || '',
      createdAt: new Date().toISOString(),
      ip: req.ip || req.connection.remoteAddress,
    };

    // Store in Redis with 90-day TTL
    const redisKey = `report:${reportId}`;
    await redisClient.setEx(redisKey, 90 * 24 * 60 * 60, JSON.stringify(reportData));

    // Also add to a list for easy retrieval
    await redisClient.lPush('report:submissions', reportId);

    console.log(`✅ Report received: ${targetType}/${targetId} - ${reason}`);

    res.status(201).json({
      success: true,
      message: 'Report submitted successfully',
      id: reportId
    });

  } catch (error) {
    console.error('❌ Report submission error:', error);
    res.status(500).json({ error: 'Failed to submit report' });
  }
});

module.exports = router;
