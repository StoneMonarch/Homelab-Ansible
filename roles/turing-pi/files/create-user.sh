# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Check if required arguments are provided
if [ $# -lt 3 ]; then
  echo "Usage: $0 <username> <password> <ssh_public_key>"
  echo "Example: $0 newuser 'MySecurePassword' 'ssh-rsa AAAAB3NzaC1yc2E...'"
  exit 1
fi

USERNAME=$1
PASSWORD=$2
SSH_KEY=$3

# Create the user
echo "Creating user: $USERNAME"
useradd -m -s /bin/bash "$USERNAME"

# Set password (non-interactively)
echo "Setting password for $USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Create sudo file for passwordless sudo
echo "Setting up passwordless sudo for $USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$USERNAME"
chmod 440 "/etc/sudoers.d/$USERNAME"

# Set up SSH key
echo "Setting up SSH key for $USERNAME"
USER_HOME=$(eval echo ~"$USERNAME")
SSH_DIR="$USER_HOME/.ssh"

# Create .ssh directory if it doesn't exist
mkdir -p "$SSH_DIR"

# Add the SSH key to authorized_keys
echo "$SSH_KEY" > "$SSH_DIR/authorized_keys"

# Set proper permissions
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"

echo "User $USERNAME has been created successfully with passwordless sudo and SSH key access."