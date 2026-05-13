# Test Fixtures

`test_key` and `test_key.pub` are a passwordless ed25519 keypair committed
intentionally for the Docker SSH integration test.

This keypair is test-only. Do not add it to any real `authorized_keys` file, and
do not use it for access to any system outside the local test container.
