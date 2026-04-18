#!/bin/bash

# Pear Messaging Backend Deployment Script
set -e

echo "🚀 Starting Pear Messaging Backend Deployment..."

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker and try again."
    exit 1
fi

# Set environment variables
export REDIS_PASSWORD=${REDIS_PASSWORD:-$(openssl rand -base64 32)}
export ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-"http://localhost:3000,https://your-domain.com"}

echo "🔧 Environment Configuration:"
echo "   Redis Password: ${REDIS_PASSWORD:0:8}..."
echo "   Allowed Origins: $ALLOWED_ORIGINS"

# Create .env file for production
cat > .env << EOF
NODE_ENV=production
PORT=3000
REDIS_URL=redis://redis:6379
REDIS_PASSWORD=$REDIS_PASSWORD
ALLOWED_ORIGINS=$ALLOWED_ORIGINS
MEDIA_TTL_DAYS=7
MAX_FILE_SIZE_MB=10
TEMP_STORAGE_PATH=./temp_media
UPLOAD_RATE_LIMIT=5
DOWNLOAD_RATE_LIMIT=20
GLOBAL_RATE_LIMIT=1000
LOG_LEVEL=info
DISABLE_ACCESS_LOGS=true
HELMET_ENABLED=true
CORS_ENABLED=true
EOF

echo "✅ Environment file created"

# Stop existing containers
echo "🛑 Stopping existing containers..."
docker-compose down --remove-orphans || true

# Build and start services
echo "🔨 Building and starting services..."
docker-compose up --build -d

# Wait for services to be healthy
echo "⏳ Waiting for services to be ready..."
sleep 10

# Check Redis health
echo "🔍 Checking Redis connection..."
if docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" ping | grep -q PONG; then
    echo "✅ Redis is healthy"
else
    echo "❌ Redis connection failed"
    docker-compose logs redis
    exit 1
fi

# Check backend health
echo "🔍 Checking backend health..."
for i in {1..30}; do
    if curl -f http://localhost:3000/health > /dev/null 2>&1; then
        echo "✅ Backend is healthy"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Backend health check failed"
        docker-compose logs backend
        exit 1
    fi
    echo "   Attempt $i/30 - waiting..."
    sleep 2
done

# Display service status
echo "📊 Service Status:"
docker-compose ps

# Display endpoints
echo "🌐 Available Endpoints:"
echo "   Health Check: http://localhost:3000/health"
echo "   Media Upload: POST http://localhost:3000/media/upload"
echo "   Media Download: GET http://localhost:3000/media/download/{token}"

# Test basic functionality
echo "🧪 Running basic tests..."

# Test health endpoint
HEALTH_RESPONSE=$(curl -s http://localhost:3000/health)
if echo "$HEALTH_RESPONSE" | grep -q '"status":"ok"'; then
    echo "✅ Health endpoint working"
else
    echo "❌ Health endpoint failed"
    echo "Response: $HEALTH_RESPONSE"
fi

# Display Redis info
echo "📈 Redis Statistics:"
docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" info memory | grep used_memory_human || true

echo ""
echo "🎉 Deployment Complete!"
echo ""
echo "📝 Next Steps:"
echo "1. Update Flutter app baseUrl to: http://localhost:3000"
echo "2. Test image upload/download functionality"
echo "3. Monitor logs: docker-compose logs -f"
echo "4. Stop services: docker-compose down"
echo ""
echo "🔒 Security Notes:"
echo "- Redis password: $REDIS_PASSWORD"
echo "- All media expires after 7 days"
echo "- Rate limiting is active"
echo "- CORS is configured for allowed origins"
echo ""
