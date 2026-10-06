#!/bin/zsh
# Empacota o 3MF Render para distribuição em um DMG (somente Apple Silicon / arm64).
#
#   ./package.sh          empacota a versão atual do Info.plist
#   ./package.sh 1.2      muda a versão para 1.2 e incrementa o número do build
#
# Desenvolvedor: Leonardo Kamache
#
# Assinatura (automática):
#   - Se houver um certificado "Developer ID Application" no Keychain, ele é usado
#     (ou defina SIGN_IDENTITY="Developer ID Application: Nome (TEAMID)" para escolher).
#   - Sem certificado, a assinatura é ad-hoc: funciona, mas quem baixar verá o aviso do
#     Gatekeeper e precisará liberar em Ajustes do Sistema → Privacidade e Segurança.
#
# Notarização (opcional, requer Developer ID):
#   xcrun notarytool store-credentials 3mf --apple-id voce@email.com --team-id TEAMID   # uma vez
#   NOTARY_PROFILE=3mf ./package.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="3MF Render"
NEW_VERSION=${1:-}
PACKAGED=0
PLIST_BACKUP=""
STAGE=""
DIST="dist"
APP="$DIST/$APP_NAME.app"
NOTARY_PROFILE=${NOTARY_PROFILE:-}

step() { print -P "\n%B==> $1%b" }
fail() { print -P "%F{red}Erro:%f $1" >&2; exit 1 }

cleanup() {
    [[ -n "$STAGE" ]] && rm -rf "$STAGE"
    if [[ -n "$PLIST_BACKUP" ]]; then
        # Se o empacotamento falhar, a versão volta ao que era: não fica "gasta" uma versão sem DMG.
        if [[ $PACKAGED != 1 ]]; then
            cp "$PLIST_BACKUP" Info.plist
            echo "Info.plist restaurado: versão não alterada." >&2
        fi
        rm -f "$PLIST_BACKUP"
    fi
}
trap cleanup EXIT

# --- Versão
# CFBundleShortVersionString = versão visível (1.2); CFBundleVersion = build (sobe a cada versão nova).
CUR_VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
CUR_BUILD=$(plutil -extract CFBundleVersion raw Info.plist)
if [[ -n "$NEW_VERSION" ]]; then
    [[ "$NEW_VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] \
        || fail "versão inválida '$NEW_VERSION' (use MAIOR.MENOR ou MAIOR.MENOR.CORREÇÃO, ex.: 1.2 ou 1.2.1)."
    autoload -Uz is-at-least
    is-at-least "$CUR_VERSION" "$NEW_VERSION" \
        || fail "a versão $NEW_VERSION é menor que a atual ($CUR_VERSION)."
    [[ "$CUR_BUILD" =~ '^[0-9]+$' ]] || fail "CFBundleVersion atual ('$CUR_BUILD') não é um número inteiro."
    PLIST_BACKUP=$(mktemp)
    cp Info.plist "$PLIST_BACKUP"
    plutil -replace CFBundleShortVersionString -string "$NEW_VERSION" Info.plist
    plutil -replace CFBundleVersion -string "$((CUR_BUILD + 1))" Info.plist
fi
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw Info.plist)
DMG="$DIST/3MF-Render-$VERSION.dmg"
if [[ -n "$NEW_VERSION" ]]; then
    echo "Versão: $CUR_VERSION (build $CUR_BUILD) → $VERSION (build $BUILD)"
else
    echo "Versão: $VERSION (build $BUILD)"
fi

# --- Identidade de assinatura
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [[ -n "$SIGN_IDENTITY" ]]; then
    DEVELOPER_ID=1
    echo "Assinando com: $SIGN_IDENTITY"
else
    DEVELOPER_ID=0
    SIGN_IDENTITY="-"
    echo "Nenhum certificado Developer ID encontrado: assinatura ad-hoc (sem notarização)."
fi
if [[ -n "$NOTARY_PROFILE" && $DEVELOPER_ID == 0 ]]; then
    fail "NOTARY_PROFILE definido, mas a notarização exige um certificado Developer ID."
fi

# --- Compilação
step "Compilando (arm64)"
ARCHS="arm64" ./build.sh
mkdir -p "$DIST"
rm -rf "$APP"          # os DMGs de versões anteriores em dist/ são mantidos
ditto "build/$APP_NAME.app" "$APP"

# --- Assinatura do app
step "Assinando o app"
if [[ $DEVELOPER_ID == 1 ]]; then
    # Hardened runtime + timestamp: obrigatórios para a notarização. O app não precisa de entitlements.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

notarize() {  # $1 = arquivo (.zip ou .dmg)
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist \
        > "$DIST/notary.plist" || true
    local notary_status=$(plutil -extract status raw "$DIST/notary.plist" 2>/dev/null || echo "?")
    if [[ "$notary_status" != "Accepted" ]]; then
        local id=$(plutil -extract id raw "$DIST/notary.plist" 2>/dev/null || echo "")
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fail "notarização de $1 retornou '$notary_status'."
    fi
    rm -f "$DIST/notary.plist"
}

# Notariza o app antes de pôr no DMG, para grampear o ticket no próprio app:
# assim ele abre sem consulta à Apple mesmo depois de copiado para /Applications.
if [[ -n "$NOTARY_PROFILE" ]]; then
    step "Notarizando o app (pode levar alguns minutos)"
    ditto -c -k --keepParent "$APP" "$DIST/app.zip"
    notarize "$DIST/app.zip"
    rm -f "$DIST/app.zip"
    xcrun stapler staple "$APP"
fi

# --- DMG com atalho para /Applications
step "Criando o DMG"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# UDZO (zlib) abre em qualquer macOS. O macOS 26+ trocou "hdiutil create" por "diskutil image create".
if diskutil image create from --help >/dev/null 2>&1; then
    out=$(diskutil image create from --format UDZO --volumeName "$APP_NAME $VERSION" "$STAGE" "$DMG" 2>&1) \
        || { echo "$out"; fail "falha ao criar o DMG."; }
else
    out=$(hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2>&1) \
        || { echo "$out"; fail "falha ao criar o DMG."; }
fi
if [[ $DEVELOPER_ID == 1 ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    step "Notarizando o DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

# --- Verificação final
step "Verificando"
echo "Arquiteturas: $(lipo -archs "$APP/Contents/MacOS/3MFRender")"
hdiutil verify "$DMG" >/dev/null 2>&1 && echo "DMG íntegro"
if [[ $DEVELOPER_ID == 1 ]]; then
    spctl --assess --type execute --verbose "$APP" || true
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
fi

PACKAGED=1
step "Pronto: $DMG — versão $VERSION (build $BUILD), $(du -h "$DMG" | cut -f1 | tr -d ' ')"
if [[ $DEVELOPER_ID == 0 ]]; then
    cat <<'EOF'
Assinatura ad-hoc: quem baixar o DMG verá o aviso do Gatekeeper na primeira abertura.
Para liberar: Ajustes do Sistema → Privacidade e Segurança → "Abrir Mesmo Assim",
ou no Terminal: xattr -dr com.apple.quarantine "/Applications/3MF Render.app"
EOF
elif [[ -z "$NOTARY_PROFILE" ]]; then
    echo "Assinado com Developer ID, mas não notarizado. Para notarizar: NOTARY_PROFILE=<perfil> ./package.sh"
fi
