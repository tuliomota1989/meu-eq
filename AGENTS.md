# MeuEQ

Equalizador do Mac só com EQ, ganho e espectro em tempo real (RTA) atrás da curva,
como na tela de EQ das mesas digitais Behringer. Swift, sem Xcode e sem driver.

<!-- cerebro:inicio -->
## Antes de começar

O cérebro do Tulio é um só: `~/cerebro`. Leia, nesta ordem:

1. `~/cerebro/mapa.md` — o índice e as regras.
2. `~/cerebro/projetos/meu-eq/README.md` — a ficha deste projeto: o que foi decidido,
   o que já quebrou e por quê.

Nunca invente caminho, porta, regra ou número que não esteja lá. Se não está, diga que
não está.

Ao terminar uma tarefa que decidiu alguma coisa, grave a decisão na ficha do projeto
no cérebro, não neste repositório.
<!-- cerebro:fim -->

## Como compilar e testar

- `./build.sh` compila e monta o `MeuEQ.app` nesta pasta. Precisa só das Command Line
  Tools; o Xcode não está instalado nesta máquina.
- `.build/release/MeuEQ --selftest` confere a matemática do EQ e do analisador.
- O SDK atual transformou o `@State` do SwiftUI em macro, e o plugin dessa macro só vem
  com o Xcode. Por isso o estado da tela fica no `EQModel` (`@Published`), nunca em
  `@State`.

## Onde está cada coisa

- `Sources/MeuEQ/AudioEngine.swift` — captura o som do sistema (Process Tap), monta o
  aggregate device privado e roda o callback de áudio.
- `Sources/MeuEQ/DSP.swift` — filtros do EQ, buffer do espectro e FFT.
- `Sources/MeuEQ/App.swift` — tela, gráfico, arrasto das bandas e o `--selftest`.
