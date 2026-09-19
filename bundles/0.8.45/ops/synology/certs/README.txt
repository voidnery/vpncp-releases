Drop your TLS certificate for the panel here, named exactly:

  fullchain.pem   (server cert + intermediate chain)
  privkey.pem     (private key)

nginx serves them on the panel port (:8443). These files MUST exist before the
stack starts, or nginx will fail to boot.

- chmod 600 privkey.pem  (keep the key private; nginx runs as root and reads it)
- Populate automatically from DSM Let's Encrypt with ../sync-cert.sh
- If your CA gives cert.pem + chain.pem separately:  cat cert.pem chain.pem > fullchain.pem
