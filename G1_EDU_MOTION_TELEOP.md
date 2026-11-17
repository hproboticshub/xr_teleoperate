# Teleoperação do G1 EDU só com a PICO (`--motion`)

Braços e mãos BrainCo seguem os comandos da PICO 4 Ultra. As pernas andam com os sticks da PICO
(locomoção da Unitree, modo `ai`). Não é preciso o comando R3 da Unitree, mas convém tê-lo por perto.

> **Segurança:** testar sempre com o robô no **pórtico**, pés a tocar no chão, e **bateria verificada**.
> Lançar o teleop toma conta dos braços do robô.

## Como funciona

```
PICO (browser, WebXR) ──Wi-Fi, túnel adb :8012──► portátil: teleop_hand_and_arm.py ──Ethernet, DDS──► G1 EDU
                                                    ▲                                             PC2 (192.168.123.164):
                                                    └──────── imagem da câmara da cabeça ◄──────── teleimager, servidor BrainCo
```

| Peça | Onde corre | Para quê |
|---|---|---|
| Servidor BrainCo (`brainco_hand.service`) | PC2, arranca no boot | liga as duas mãos (DDS `rt/brainco/*`) |
| teleimager | PC2 | envia a câmara da cabeça para o portátil e daí para a PICO |
| `video_hub_pc4` (Unitree) | PC2 | ocupa a câmara da cabeça: **tem de estar desligado** |
| Túnel adb 8012 | portátil ↔ PICO | o browser da PICO não aceita o certificado do portátil por Wi-Fi |
| `teleop_hand_and_arm.py --motion` | portátil | IK dos braços (`rt/arm_sdk`), mãos, sticks → locomoção |

## Instalação (uma vez)

1. Seguir o [README](README.md) para o ambiente conda `tv` e o `unitree_sdk2_python`.
2. Clonar este branch com os submódulos e aplicar o patch do televuer (obrigatório: watchdog da PICO):

   ```bash
   git clone -b arms_with_offset --recursive git@github.com:hproboticshub/xr_teleoperate.git
   cd xr_teleoperate
   git -C teleop/televuer apply ../../patches/televuer/0001-last-motion-time-for-pico-watchdog.patch
   ```

   O patch `0002` (offset dos braços por variável de ambiente) é opcional, ver
   [patches/televuer/README.md](patches/televuer/README.md).
3. Certificado TLS do televuer em `~/.config/xr_teleoperate/{cert,key}.pem` (ver README).
4. No PC2 (`unitree@192.168.123.164`): teleimager instalado em `~/teleimager` e
   `scripts/g1_edu/start_teleimager.sh` copiado para `~/start_teleimager.sh`.
5. Na PICO: modo de programador e depuração USB ativos.

## Em cada sessão

Todos os comandos no portátil, dentro de `xr_teleoperate`, com `conda activate tv`.
`IFACE` é o adaptador USB-Ethernet ligado ao robô (o que tem IP `192.168.123.x`):

```bash
ip -br addr | grep 192.168.123      # ex.: enxf44dad0705a2
IFACE=enxf44dad0705a2
```

### 1. Robô e rede

```bash
ping -c1 192.168.123.161 && ping -c1 192.168.123.164      # PC1 e PC2
python scripts/g1_edu/check_loco.py $IFACE                # modo 'ai' e FSM (só leitura)
```

Logo depois de ligar o robô o FSM pode dar `erro 3102`: esperar 1 minuto.

### 2. Mãos BrainCo

```bash
python scripts/g1_edu/read_brainco.py $IFACE     # as duas mãos devem ter ~180 msgs em 2 s
```

Se uma mão (ou as duas) tiver **0 msgs**, reiniciar o serviço (pede a password sudo do PC2):

```bash
ssh -t unitree@192.168.123.164 "sudo systemctl restart brainco_hand.service"
```

Acontece quase sempre depois de ligar o robô. Não lançar um segundo servidor à mão (falha com `Failed to open /dev/ttyUSB…`).

### 3. Câmara da cabeça

```bash
python scripts/g1_edu/svc_list.py $IFACE | grep video_hub_pc4      # status=0 = a correr
python scripts/g1_edu/svc_switch.py $IFACE video_hub_pc4 off        # volta a ligar-se em cada arranque do robô
timeout 5 ssh -n unitree@192.168.123.164 '~/start_teleimager.sh'    # o ssh não volta sozinho, daí o timeout
```

O teleimager responde na porta 60000 do PC2 (log em `PC2:/tmp/teleimager.log`).

### 4. PICO

O portátil e a PICO na mesma rede Wi-Fi. IP da PICO: `PICO=192.168.10.170:5555` (DHCP, pode mudar).

```bash
adb connect $PICO
adb -s $PICO reverse tcp:8012 tcp:8012
```

Se o `adb connect` disser `Connection refused`, a PICO foi reiniciada: ligá-la por USB, aceitar a depuração USB,
`adb tcpip 5555`, desligar o cabo e repetir. Se a PICO adormecer, acordá-la e refazer o `reverse`.

### 5. Teleop

```bash
cd teleop
python teleop_hand_and_arm.py --input-mode=controller --arm=G1_29 --ee=brainco --motion --network-interface=$IFACE
```

Na PICO, abrir no browser **`https://localhost:8012/?ws=wss://localhost:8012`** e carregar em **Virtual Reality**.
O teleop espera pela PICO e escreve `[PICO] connected`.

Pôr os comandos na pose dos braços do robô e começar com **A+X durante 1 s** (ou `r` no terminal).

## Atalho: script único

`scripts/run_g1_teleop.sh` faz os passos 3 e 5 (liberta a câmara, sobe o teleimager no PC2, aplica os patches do
televuer e lança o teleop com `--motion --input-mode controller`). O robô **não** entra em dev mode.

```bash
scripts/run_g1_teleop.sh --ee brainco                                  # padrão
scripts/run_g1_teleop.sh --ee brainco --arm-offset-x -0.15 --arm-offset-z 0.50 --arm-offset-y 0.02
scripts/run_g1_teleop.sh --dev-mode --ee brainco                       # força dev mode (sem FSM/pernas pela PICO)
```

## Controlos da PICO

| Comando | Efeito |
|---|---|
| **B+Y** 1 s | levantar: sai do debug mode se for preciso, Damp → StandUp → Regular mode (FSM 500) |
| **A+X** 1 s | começar a seguir os comandos / retomar depois de parar |
| **clicar os dois sticks** 0,5 s | **parar**: velocidade zero, braços e mãos congelados, o robô continua de pé |
| **A+B+X+Y** 1 s | sair do teleop (ou `q` no terminal; não usar Ctrl+C) |
| Stick esquerdo / direito | andar / rodar (velocidade limitada a 0,3) |
| Gatilho / grip | fechar a mão / fechar o indicador |
| (automático) | sem dados da PICO durante 0,3 s = paragem até os dados voltarem |

## No fim

```bash
adb reverse --remove-all; adb kill-server
python scripts/g1_edu/svc_switch.py $IFACE video_hub_pc4 on      # se a app da Unitree precisar de vídeo
```

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `enx…: does not match an available interface` | adaptador errado ou desligado | `ip -br addr`, usar o `IFACE` com `192.168.123.x` |
| `[Brainco_Controller_ctrl] Waiting to subscribe dds...` sem fim | servidor BrainCo não publica | passo 2: reiniciar o serviço |
| `Request to 192.168.123.164:60000 timed out` | teleimager parado | passo 3 |
| teleimager não arranca | `video_hub_pc4` ligado | passo 3 (`svc_switch … off`) |
| PICO não liga / página não abre | túnel adb caiu (PICO adormeceu ou foi reiniciada) | passo 4 |
| braços congelados com `[PICO] no data` | PICO adormecida, VR fechado ou túnel em baixo | acordar a PICO, refazer o túnel |
| `Maximum_Iterations_Exceeded` no IK | comandos longe da pose do braço do robô | inofensivo; aproximar os comandos da pose do robô |
| braços do robô demasiado à frente / esticados | offset cabeça→cintura da Unitree | patch `0002` e `XR_ARM_OFFSET_X=-0.15` |
