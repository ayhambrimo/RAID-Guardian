# ============================================================================
# RAID Guardian v4.0 - Multi-Vendor Edition (Temperature & Health Monitoring)
# Developer: Ayham Brimo
#
# Supports:
#   - HPE Smart Array / SSA    -> ssacli
#   - Dell PERC                -> perccli / perccli64
#   - LSI / Broadcom / Avago   -> storcli / storcli64
#   - Adaptec / Microsemi/HBA  -> arcconf
#
# Adds: controller + per-drive temperature thresholds, battery/cache health,
# drive-count summaries, optional webhook/email alerting.
#
# Written for POSIX sh (busybox ash) so it runs unmodified on ESXi's
# built-in shell, no bash required.
# ============================================================================