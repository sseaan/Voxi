#!/usr/bin/env bash
# 创建本地自签名 Code Signing identity（不依赖 Apple Developer ID）。
#
# 为什么需要：ad-hoc 签名（CODE_SIGN_IDENTITY=-）每次构建都会得到新的签名，
# macOS 会把每个构建当成不同 app，反复重新申请麦克风/辅助功能授权。
# 固定的自签名证书让签名与 TCC 授权在构建之间保持稳定；但它不是 Developer ID，
# 也没有 notarization，Gatekeeper 首次启动仍可能需要用户手动批准。
#
# 用法：
#   scripts/create-local-signing-identity.sh                       # 不存在时创建
#   scripts/create-local-signing-identity.sh "Some Other Identity" # 指定名称
set -euo pipefail

IDENTITY_NAME="${1:-Voxi Self-Signed Code Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
BACKUP_DIR="${HOME}/.voxi/signing"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "$IDENTITY_NAME"; then
  echo "Signing identity already present: $IDENTITY_NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

echo "==> 生成自签名 code-signing 证书"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/cert.cnf" >/dev/null 2>&1

# macOS 的 security 工具读不了新版 PKCS#12（AES/PBKDF2），使用 legacy 编码 + 随机口令。
P12_PASSWORD="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY_NAME" -out "$WORK/identity.p12" \
  -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

echo "==> 导入 login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null

echo "==> 设置该证书的代码签名信任"
# 用户域信任，无需 sudo。
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  || echo "warning: 无法自动设置信任；请在 Keychain Access → 证书 中手动信任"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY_NAME" -out "$BACKUP_DIR/${IDENTITY_NAME// /-}.p12" \
  -passout "pass:$P12_PASSWORD" >/dev/null 2>&1
printf '%s' "$P12_PASSWORD" > "$BACKUP_DIR/${IDENTITY_NAME// /-}.password"
chmod 600 "$BACKUP_DIR"/*

echo
echo "已创建 identity: $IDENTITY_NAME"
echo "私钥备份（请自行保管，禁止提交 Git）：$BACKUP_DIR"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$IDENTITY_NAME" || true
