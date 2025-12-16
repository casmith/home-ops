
  Steps to Deploy Custom Runner:

  1. Build and push the custom image:

  # Navigate to the runner image directory
  cd /home/clay/work/home-ops/kubernetes/apps/actions-runner-system/khaoslabs-runners/runner-image

  # Build the image (this will take a few minutes)
  docker build -t ghcr.io/khaoslabs/actions-runner:latest .

  # Login to GitHub Container Registry
  # First, create a Personal Access Token at: https://github.com/settings/tokens
  # Required scopes: write:packages, read:packages
  echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

  # Push the image
  docker push ghcr.io/khaoslabs/actions-runner:latest

  2. Make the package public (or grant runner access):

  After pushing:
  - Go to: https://github.com/orgs/khaoslabs/packages
  - Click on your actions-runner package
  - Go to "Package settings"
  - Either:
    - Change visibility to "Public", OR
    - Add the runner service account to have read access

  3. Deploy the updated runner configuration:

  cd /home/clay/work/home-ops
  git add kubernetes/apps/actions-runner-system/
  git commit -m "feat: add custom runner image with Ansible"
  git push

  Flux will automatically update the runners to use your custom image with Ansible pre-installed.

  4. Verify Ansible is available:

  Create a test workflow:
  name: Test Ansible
  on: push
  jobs:
    test:
      runs-on: khaoslabs-runners
      steps:
        - run: ansible --version
        - run: ansible-galaxy collection list

  ---
  Alternative: Option 2 - Install Ansible in Workflow (Simpler)

  If you don't want to maintain a custom image, you can install Ansible in each workflow run:

  jobs:
    deploy:
      runs-on: khaoslabs-runners
      steps:
        - uses: actions/checkout@v4

        - name: Install Ansible
          run: |
            sudo apt-get update
            sudo apt-get install -y python3-pip
            pip3 install ansible

        - name: Run your playbook
          run: ansible-playbook -i hosts.yaml playbook.yaml
