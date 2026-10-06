# 3MF Render

App para macOS: uma janela pequena onde você arrasta um arquivo `.3mf` e vê o render 3D do **plate 1** — e pode escolher os outros plates.

Desenvolvido por **Leonardo Kamache**.

## Compilar

    ./build.sh          # gera build/3MF Render.app (precisa apenas das Command Line Tools)

## Distribuir

    ./package.sh        # gera dist/3MF-Render-<versão>.dmg (Apple Silicon) com a versão atual
    ./package.sh 1.2    # muda a versão para 1.2, incrementa o build e gera o DMG

- Sem certificado: assinatura ad-hoc. Quem baixar precisa liberar o app na primeira abertura
  (Ajustes do Sistema → Privacidade e Segurança → "Abrir Mesmo Assim").
- Com um certificado "Developer ID Application" no Keychain, o script assina automaticamente.
  Para também notarizar (o app abre sem avisos em qualquer Mac):

      xcrun notarytool store-credentials 3mf --apple-id voce@email.com --team-id TEAMID   # uma vez
      NOTARY_PROFILE=3mf ./package.sh

- Versão (`CFBundleShortVersionString`) e build (`CFBundleVersion`) ficam no `Info.plist`.
  Convenção: 1.1 → 1.1.1 para correções, 1.1 → 1.2 para funções novas, 2.0 para mudanças grandes.
  O script não aceita versão menor que a atual e, se falhar, desfaz a mudança de versão.

## Usar

- Arraste um `.3mf` para a janela (ou ⌘O, ou "Abrir com" no Finder).
- Arraste com o mouse para girar. Scroll do mouse (ou dois dedos/pinça no trackpad) faz zoom na direção do cursor — rolar para baixo aproxima, para cima afasta. ⌘0 redefine a câmera.
- Arquivos com vários plates: menu no canto inferior esquerdo, ⌘[ e ⌘] para o plate anterior/próximo, ou clique com o botão direito para pular para o próximo (depois do último, volta ao primeiro).
- "3D / Fatiador": alterna entre o render próprio e a imagem do plate 1 salva pelo Bambu Studio (quando existir).
- ⌘S salva a imagem em PNG.

Linha de comando (render sem janela):

    "build/3MF Render.app/Contents/MacOS/3MFRender" --render arquivo.3mf saida.png 800 [plate]

## Suporte

- Bambu Studio / OrcaSlicer: vários plates, objetos em `3D/Objects/*.model`, cor por filamento/parte e pintura multicolor (`paint_color`).
- Partes negativas, modificadores e bloqueadores de suporte não são desenhados (como no fatiador).
- PrusaSlicer: volumes com extrusoras e pintura (`mmu_segmentation`).
- 3MF genérico: `basematerials` / `colorgroup`.
