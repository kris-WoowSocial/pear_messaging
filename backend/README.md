# Pear Messaging Backend - EC2 Deployment Guide

## Quick Deploy to EC2

### Prerequisites
- EC2 instance running Ubuntu 20.04+ 
- SSH access to your EC2 instance
- Security group allowing HTTP (port 80) and SSH (port 22)

### 1. Upload Files to EC2
```bash
# From your local machine, upload the backend folder
scp -r backend/ ubuntu@YOUR_EC2_IP:/tmp/pear-messaging-backend

# Or use rsync for better performance
rsync -avz --progress backend/ ubuntu@YOUR_EC2_IP:/tmp/pear-messaging-backend
```

### 2. SSH to EC2 and Deploy
```bash
# SSH to your EC2 instance
ssh ubuntu@YOUR_EC2_IP

# Navigate to uploaded files
cd /tmp/pear-messaging-backend

# Run deployment script
./ec2-deploy.sh
```

### 3. Update Flutter App
After deployment, update your Flutter app's base URL:

```dart
// In lib/core/services/media_service.dart
static const String baseUrl = 'http://YOUR_EC2_PUBLIC_IP';
```

## What the Deployment Script Does

### System Setup
- ✅ Updates Ubuntu packages
- ✅ Installs Node.js 18 LTS
- ✅ Installs Redis server
- ✅ Installs Nginx reverse proxy
- ✅ Installs PM2 process manager

### Security Configuration
- ✅ Configures Redis with password authentication
- ✅ Sets up UFW firewall (ports 22, 80, 443)
- ✅ Configures Nginx with security headers
- ✅ Implements rate limiting
- ✅ Runs app as non-root user

### Application Setup
- ✅ Creates `/opt/pear-messaging-backend` directory
- ✅ Installs production dependencies
- ✅ Configures environment variables
- ✅ Sets up PM2 clustering
- ✅ Configures log rotation

### Nginx Configuration
- ✅ Reverse proxy on port 80
- ✅ Rate limiting for media endpoints
- ✅ Security headers
- ✅ Large file upload support (10MB)

## Post-Deployment Management

### View Application Status
```bash
pm2 status
pm2 logs pear-messaging
```

### Restart Application
```bash
pm2 restart pear-messaging
```

### View System Logs
```bash
# Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# Redis logs
sudo journalctl -u redis-server -f
```

### Monitor Resources
```bash
# System resources
htop

# Redis memory usage
redis-cli -a YOUR_REDIS_PASSWORD info memory

# Disk usage
df -h
```

## API Endpoints

Once deployed, your API will be available at:

- **Health Check**: `GET http://YOUR_EC2_IP/health`
- **Upload Media**: `POST http://YOUR_EC2_IP/media/upload`
- **Download Media**: `GET http://YOUR_EC2_IP/media/download/{token}`
- **Check Token**: `HEAD http://YOUR_EC2_IP/media/download/{token}`

## Security Features

### Rate Limiting
- Upload: 5 requests/minute per IP
- Download: 20 requests/minute per IP
- General API: 1000 requests/15 minutes per IP

### Data Protection
- Redis password protected
- No user data stored in Redis
- Automatic 7-day media expiry
- Encrypted media storage
- Security headers enabled

### Network Security
- UFW firewall configured
- Only necessary ports open
- Nginx reverse proxy
- No direct Node.js exposure

## Troubleshooting

### Service Not Starting
```bash
# Check PM2 status
pm2 status
pm2 logs pear-messaging --lines 50

# Check Redis
sudo systemctl status redis-server
redis-cli -a YOUR_REDIS_PASSWORD ping

# Check Nginx
sudo systemctl status nginx
sudo nginx -t
```

### High Memory Usage
```bash
# Restart PM2 cluster
pm2 restart pear-messaging

# Check Redis memory
redis-cli -a YOUR_REDIS_PASSWORD info memory
```

### Upload Failures
```bash
# Check disk space
df -h

# Check temp directory permissions
ls -la /opt/pear-messaging-backend/temp_media

# Check Nginx upload limits
sudo nginx -T | grep client_max_body_size
```

## Scaling Considerations

### Horizontal Scaling
- Use Application Load Balancer
- Deploy to multiple EC2 instances
- Use ElastiCache for Redis
- Implement sticky sessions

### Vertical Scaling
- Increase EC2 instance size
- Adjust PM2 instance count
- Increase Redis memory limit
- Optimize Nginx worker processes

## Backup Strategy

### Redis Backup
```bash
# Manual backup
redis-cli -a YOUR_REDIS_PASSWORD BGSAVE

# Automated backup (add to crontab)
0 2 * * * redis-cli -a YOUR_REDIS_PASSWORD BGSAVE
```

### Application Backup
```bash
# Backup configuration
tar -czf pear-backup-$(date +%Y%m%d).tar.gz /opt/pear-messaging-backend
```

## SSL/HTTPS Setup (Optional)

### Using Let's Encrypt
```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d your-domain.com

# Auto-renewal
sudo crontab -e
# Add: 0 12 * * * /usr/bin/certbot renew --quiet
```

## Monitoring Setup

### Basic Monitoring
```bash
# Install monitoring tools
sudo apt install htop iotop nethogs

# Monitor in real-time
watch -n 1 'pm2 status && echo "---" && free -h && echo "---" && df -h'
```

### Advanced Monitoring
Consider setting up:
- CloudWatch for AWS monitoring
- Prometheus + Grafana for metrics
- ELK stack for log analysis
- Uptime monitoring service

## Support

For issues or questions:
1. Check the logs: `pm2 logs pear-messaging`
2. Verify health endpoint: `curl http://YOUR_EC2_IP/health`
3. Check system resources: `htop` and `df -h`
4. Review security groups and firewall settings
