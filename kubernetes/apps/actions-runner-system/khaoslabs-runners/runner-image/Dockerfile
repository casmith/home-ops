# Custom GitHub Actions runner with Ansible
FROM ghcr.io/actions/actions-runner:latest

USER root

# Install Python and Ansible dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    sshpass \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible
RUN pip3 install --no-cache-dir \
    ansible \
    ansible-core \
    jmespath

# Install Docker (if you need docker-in-docker for your workflows)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install community.docker collection (if you need it)
RUN ansible-galaxy collection install community.docker

USER runner

# Verify installations
RUN ansible --version && docker --version
