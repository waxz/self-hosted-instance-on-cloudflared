# Stop service
net stop w32time

# Unregister
w32tm /unregister

# Register
w32tm /register

# Configure with multiple reliable servers
w32tm /config /manualpeerlist:"time.cloudflare.com" /syncfromflags:manual /reliable:YES /update

# Start service
net start w32time

# Wait a moment
Start-Sleep -Seconds 3

# Resync with rediscover
w32tm /resync /rediscover

