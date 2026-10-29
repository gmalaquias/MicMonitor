# MicMonitor

Widget para Windows, sempre visível na tela, que acompanha o microfone de um fone Bluetooth e melhora a voz que
chega ao Teams (ou a qualquer app de chamada).

Feito em PowerShell + WPF, com chamadas diretas à Core Audio API (WASAPI) via `Add-Type`. Não precisa de build.
Funciona no Windows 10/11 com o Windows PowerShell 5.1.

## O que ele faz

- **Volume do microfone**: mostra o volume do microfone do fone (ex.: `AE01 ▬▬▬ 100%`). A barra fica amarela
  abaixo de 80% e vermelha abaixo de 40% ou quando está no mudo.
- **Medidor de voz**: mostra em tempo real o nível do que está sendo captado. O medidor é passivo: não abre o
  microfone sozinho, então o fone não fica preso no perfil Hands-Free.
- **Fone desligado**: o widget encolhe para um selo cinza `AE01 off` e volta sozinho quando o fone reconecta.
- **Ícone perto do relógio**: um microfone na área de notificação com a cor do estado (verde, amarelo, vermelho ou
  cinza) e um ponto roxo quando a ponte de voz está ativa. Passando o mouse, mostra o volume e o ganho.
- **Ocultar**: o widget pode ficar escondido, só com o ícone perto do relógio. O estado fica salvo entre reinícios.
- **Log de quedas** (`quedas.log`): registra cada queda de volume com os apps que estavam usando o microfone,
  e cada conexão e desconexão do fone. Serve para descobrir quem está baixando o volume.
- **Melhorar voz** (requer [VB-CABLE](https://vb-audio.com/Cable/)): quando algum app capta do microfone
  `CABLE Output`, o widget capta o fone em modo **RAW** (sem os efeitos de áudio do Windows), aplica um **ganho**
  configurável (+6 a +24 dB) e um **limitador**, e toca o resultado no `CABLE Input`. A ponte só roda enquanto algum
  app usa o `CABLE Output`.
- **Mic padrão = CABLE**: com o fone ligado, mantém o `CABLE Output` como microfone padrão e de comunicação do
  Windows. Com o fone desligado, ou ao fechar o widget, devolve o padrão para outro microfone, para nenhum app
  ficar mudo.

## Uso

- **Arrastar**: move o widget (a posição fica salva).
- **Duplo clique**: volta o volume do microfone para 100%.
- **Botão direito**: menu com as opções:
  - Melhorar voz
  - Ganho da voz
  - Manter CABLE Output como mic padrão do Windows
  - Voltar volume do mic para 100%
  - Manter volume em 100% automaticamente
  - Abrir log
  - Ocultar (fica só o ícone perto do relógio)
  - Fechar
- **Ícone perto do relógio**: clique esquerdo mostra ou oculta o widget. O botão direito abre um menu com Mostrar widget,
  Melhorar voz, Ganho da voz, Abrir log e Fechar.
- Se a posição salva ficar fora da tela (por exemplo, atrás da barra de tarefas), o widget volta sozinho para a área visível.

## Instalação

1. Copie a pasta para, por exemplo, `C:\Users\<voce>\Tools\MicMonitor`.
2. Para abrir: dois cliques em `MicMonitor.cmd`.
3. Para abrir junto com o Windows: crie um atalho na pasta `shell:startup` com
   - Destino: `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<pasta>\MicMonitor.ps1"`
4. (Opcional, para "Melhorar voz") instale o VB-CABLE e, no Teams, escolha o microfone **CABLE Output**.

## Configuração (`config.json`, criado na primeira execução)

| Chave | Padrão | Descrição |
|---|---|---|
| `Alvo` | `AE01` | Parte do nome do fone Bluetooth a monitorar |
| `MelhorarVoz` | `true` | Liga a ponte de voz via VB-CABLE |
| `GanhoDb` | `15` | Ganho aplicado na ponte |
| `MicPadraoCable` | `true` | Mantém o CABLE Output como mic padrão enquanto o fone estiver ligado |
| `MicSemFone` | `Grupo de microfones` | Mic que vira padrão quando o fone desliga |
| `ManterEm100` | `false` | Restaura o volume do mic para 100% sempre que cair |
| `Oculto` | `false` | Abre com o widget oculto, só com o ícone perto do relógio |

## Diagnóstico (`MicDiag.ps1`)

Grava 20 s do microfone do fone em dois modos ao mesmo tempo, **RAW** (sem efeitos) e **COMM** (o que o app de
chamada recebe), e mostra o nível da voz a cada 2 s. Assim dá para ver se a voz cai na origem ou no processamento
do Windows.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MicDiag.ps1
# ou grava o que chega pelo VB-CABLE:
powershell -NoProfile -ExecutionPolicy Bypass -File .\MicDiag.ps1 -Desc "CABLE Output"
```

## Observações

- Para trocar o dispositivo padrão, o widget usa a interface `IPolicyConfig`, que não é documentada (é a mesma
  usada pelo SoundSwitch e pelo AudioDeviceCmdlets).
- Se o widget for fechado com o Teams usando `CABLE Output`, o Teams recebe silêncio.
