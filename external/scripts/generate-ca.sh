#!/usr/bin/env bash
# =============================================================================
# generate-ca.sh
#
# Creates the custom RAUC signing CA used to sign GPU/AI OTA bundles. Run ONCE.
#
#   cert.pem  -> PUBLIC. HAOS bakes it into /etc/rauc/keyring.pem at build time
#                (it is picked up from the build dir), so bundles signed by this
#                CA install, and stock Home-Assistant-signed bundles do not.
#   key.pem   -> SECRET. Store as the GitHub Actions secret RAUC_SIGNING_KEY.
#                The CI writes it back into the build dir at build time.
#
# Never commit key.pem.
# =============================================================================
set -euo pipefail

OUT="${1:-./pki}"
mkdir -p "$OUT"

openssl req -x509 -newkey rsa:4096 -nodes \
	-keyout "$OUT/key.pem" \
	-out "$OUT/cert.pem" \
	-days 3650 \
	-subj "/O=HAOS-GPU-AI/CN=HAOS-GPU-AI Release CA"

chmod 600 "$OUT/key.pem"
echo "CA written to ${OUT}/"
echo "  - commit cert.pem (public)"
echo "  - add key.pem contents to GitHub secret RAUC_SIGNING_KEY (keep secret)"
