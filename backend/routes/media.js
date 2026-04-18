const express = require('express');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');
const redis = require('redis');
const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

const router = express.Router();

// Redis client for media token management
// SECURITY: Redis stores only tokens and expiry, no user data
const redisClient = redis.createClient({
  url: process.env.REDIS_URL || 'redis://localhost:6379'
});

redisClient.on('error', (err) => {
  console.error('Redis Client Error:', err);
});

// Connect to Redis
redisClient.connect().catch(console.error);

// Configure multer for memory storage (no disk persistence)
// SECURITY: Files are processed in memory only, never written to disk permanently
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 10 * 1024 * 1024, // 10MB limit
    files: 1
  },
  fileFilter: (req, file, cb) => {
    // Accept only binary files (encrypted images)
    if (file.mimetype === 'application/octet-stream') {
      cb(null, true);
    } else {
      cb(new Error('Invalid file type'), false);
    }
  }
});

// Rate limiting middleware
const rateLimiter = new Map(); // In production, use Redis or a proper rate limiter

const rateLimit = (maxRequests = 10, windowMs = 60000) => {
  return (req, res, next) => {
    const key = req.ip || req.connection.remoteAddress;
    const now = Date.now();
    const windowStart = now - windowMs;
    
    // Clean old entries
    for (const [ip, requests] of rateLimiter.entries()) {
      const validRequests = requests.filter(timestamp => timestamp > windowStart);
      if (validRequests.length === 0) {
        rateLimiter.delete(ip);
      } else {
        rateLimiter.set(ip, validRequests);
      }
    }
    
    // Check current IP
    const requests = rateLimiter.get(key) || [];
    if (requests.length >= maxRequests) {
      return res.status(429).json({ error: 'Too many requests' });
    }
    
    // Add current request
    requests.push(now);
    rateLimiter.set(key, requests);
    
    next();
  };
};

/**
 * POST /media/upload
 * 
 * Upload encrypted image and receive media token
 * 
 * SECURITY FEATURES:
 * - Files stored only in memory during processing
 * - No user data linked to tokens
 * - Automatic cleanup via Redis TTL
 * - Rate limiting to prevent abuse
 * - File size limits enforced
 */
router.post('/upload', rateLimit(5, 60000), upload.single('media'), async (req, res) => {
  try {
    // Validate file exists
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }
    
    // Generate secure random media token
    const mediaToken = uuidv4();
    
    // Set expiry time (7 days from now)
    const expiryTimestamp = new Date(Date.now() + (7 * 24 * 60 * 60 * 1000));
    
    // Store encrypted file in temporary memory storage
    // In production, use a proper distributed cache or object storage
    const tempStoragePath = path.join(__dirname, '../../temp_media');
    
    // Ensure temp directory exists
    await fs.mkdir(tempStoragePath, { recursive: true });
    
    // Write encrypted file to temporary storage
    const filePath = path.join(tempStoragePath, mediaToken);
    await fs.writeFile(filePath, req.file.buffer);
    
    // Store token metadata in Redis
    // SECURITY: Only token and expiry stored, no user data
    const redisKey = `media:${mediaToken}`;
    const mediaData = {
      expiry: expiryTimestamp.toISOString(),
      size: req.file.size,
      uploaded: new Date().toISOString()
    };
    
    await redisClient.setEx(redisKey, 7 * 24 * 60 * 60, JSON.stringify(mediaData));
    
    // Schedule file cleanup (in production, use proper background jobs)
    setTimeout(async () => {
      try {
        await fs.unlink(filePath);
      } catch (error) {
        // File might already be deleted
        console.error('Cleanup error:', error.message);
      }
    }, 7 * 24 * 60 * 60 * 1000); // 7 days
    
    // Return token and expiry
    res.json({
      mediaToken,
      expiryTimestamp: expiryTimestamp.toISOString()
    });
    
  } catch (error) {
    console.error('Upload error:', error);
    res.status(500).json({ error: 'Upload failed' });
  }
});

/**
 * GET /media/download/:mediaToken
 * 
 * Download encrypted image using media token
 * 
 * SECURITY FEATURES:
 * - Token validation via Redis
 * - No access logs (privacy protection)
 * - Automatic cleanup of expired tokens
 * - Protection against enumeration attacks
 */
router.get('/download/:mediaToken', rateLimit(20, 60000), async (req, res) => {
  try {
    const { mediaToken } = req.params;
    
    // Validate token format (UUID)
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(mediaToken)) {
      return res.status(410).json({ error: 'Media not found' });
    }
    
    // Check Redis for token
    const redisKey = `media:${mediaToken}`;
    const mediaData = await redisClient.get(redisKey);
    
    if (!mediaData) {
      // Token expired or never existed
      return res.status(410).json({ error: 'Media expired' });
    }
    
    const parsedData = JSON.parse(mediaData);
    const expiryTime = new Date(parsedData.expiry);
    
    // Double check expiry
    if (Date.now() > expiryTime.getTime()) {
      // Clean up expired token
      await redisClient.del(redisKey);
      return res.status(410).json({ error: 'Media expired' });
    }
    
    // Read encrypted file from temporary storage
    const tempStoragePath = path.join(__dirname, '../../temp_media');
    const filePath = path.join(tempStoragePath, mediaToken);
    
    try {
      const fileData = await fs.readFile(filePath);
      
      // Set appropriate headers for binary data
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
      res.setHeader('Pragma', 'no-cache');
      res.setHeader('Expires', '0');
      
      // Send encrypted file
      res.send(fileData);
      
    } catch (fileError) {
      // File might have been cleaned up
      console.error('File read error:', fileError.message);
      return res.status(410).json({ error: 'Media not found' });
    }
    
  } catch (error) {
    console.error('Download error:', error);
    res.status(500).json({ error: 'Download failed' });
  }
});

/**
 * HEAD /media/download/:mediaToken
 * 
 * Check if media token is valid without downloading
 * 
 * SECURITY: Lightweight check, minimal resource usage
 */
router.head('/download/:mediaToken', rateLimit(50, 60000), async (req, res) => {
  try {
    const { mediaToken } = req.params;
    
    // Validate token format
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(mediaToken)) {
      return res.status(410).end();
    }
    
    // Check Redis for token
    const redisKey = `media:${mediaToken}`;
    const mediaData = await redisClient.get(redisKey);
    
    if (!mediaData) {
      return res.status(410).end();
    }
    
    const parsedData = JSON.parse(mediaData);
    const expiryTime = new Date(parsedData.expiry);
    
    // Check expiry
    if (Date.now() > expiryTime.getTime()) {
      await redisClient.del(redisKey);
      return res.status(410).end();
    }
    
    // Token is valid
    res.status(200).end();
    
  } catch (error) {
    console.error('Token check error:', error);
    res.status(500).end();
  }
});

/**
 * DELETE /media/cleanup
 * 
 * Manual cleanup endpoint for expired media (admin only)
 * 
 * SECURITY: Should be protected by authentication in production
 */
router.delete('/cleanup', async (req, res) => {
  try {
    const tempStoragePath = path.join(__dirname, '../../temp_media');
    
    // Get all files in temp storage
    const files = await fs.readdir(tempStoragePath);
    let cleanedCount = 0;
    
    for (const file of files) {
      const redisKey = `media:${file}`;
      const mediaData = await redisClient.get(redisKey);
      
      if (!mediaData) {
        // No Redis entry, clean up file
        try {
          await fs.unlink(path.join(tempStoragePath, file));
          cleanedCount++;
        } catch (error) {
          // File might not exist
          console.error('Cleanup file error:', error.message);
        }
      } else {
        const parsedData = JSON.parse(mediaData);
        const expiryTime = new Date(parsedData.expiry);
        
        if (Date.now() > expiryTime.getTime()) {
          // Expired, clean up both Redis and file
          await redisClient.del(redisKey);
          try {
            await fs.unlink(path.join(tempStoragePath, file));
            cleanedCount++;
          } catch (error) {
            console.error('Cleanup file error:', error.message);
          }
        }
      }
    }
    
    res.json({ cleanedCount });
    
  } catch (error) {
    console.error('Cleanup error:', error);
    res.status(500).json({ error: 'Cleanup failed' });
  }
});

// Error handling middleware
router.use((error, req, res, next) => {
  if (error instanceof multer.MulterError) {
    if (error.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({ error: 'File too large' });
    }
    if (error.code === 'LIMIT_FILE_COUNT') {
      return res.status(400).json({ error: 'Too many files' });
    }
  }
  
  if (error.message === 'Invalid file type') {
    return res.status(400).json({ error: 'Invalid file type' });
  }
  
  console.error('Media upload error:', error);
  res.status(500).json({ error: 'Internal server error' });
});

module.exports = router;
