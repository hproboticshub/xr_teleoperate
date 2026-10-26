# Teleoperação XR do G1-D (PICO 4 Ultra + BrainCo)

Guia do nosso setup. Para a arquitetura geral, veja o [README](README.md) oficial.

## Setup

| Equipamento | Endereço | Notas |
|---|---|---|
| Notebook (Wi-Fi) | 192.168.10.123 | mesma rede do PICO |
| Notebook (rede do robô) | 192.168.123.99 | adaptador `enxf44dad0705a2` |
| G1 PC2 | 192.168.123.164 | usuário `unitree`, interface `eth0` |
| PICO | 192.168.10.170 | DHCP, pode mudar |

- Modo de controle: **debug mode** (sem `--motion`). O modo ai do G1-D ignora o `rt/arm_sdk`.
- Entrada: **controles** (`--input-mode=controller`). O browser do PICO não envia hand tracking.
- Mãos: **BrainCo** (`--ee=brainco`), servidor no PC2.
- Vídeo: PC2 → ZMQ → notebook → PICO. O WebRTC da câmera da cabeça está desligado no PC2 (`enable_webrtc: false` em `cam_config_server.yaml`).

## Instalação (uma vez só)

### Notebook

Não tem conda: usamos o **micromamba**. O pinocchio 3.1.0 só existe no conda-forge, não no PyPI, por isso `venv` não serve.

```bash
# inicializar o micromamba no zsh (depois abrir um terminal novo)
micromamba shell init --shell zsh --root-prefix=~/micromamba

# ambiente
micromamba create -n tv python=3.10 pinocchio=3.1.0 numpy=1.26.4 -c conda-forge
micromamba activate tv

# repositório + submódulos
cd ~/git_projects/xr_teleoperate
git submodule update --init --depth 1

cd teleop/teleimager && pip install -e . --no-deps && cd ../..
cd teleop/televuer && pip install -e . && cd ../..
pip install "params-proto<3" pyyaml pyzmq   # vuer 0.0.60 não inicia com params-proto 3; o teleimager precisa de pyyaml/pyzmq

# fora do README, mas necessário
pip install -r requirements.txt
pip install -e teleop/robot_control/dex-retargeting

# SDK da Unitree (commit >= 404fe44)
cd ~/git_projects/unitree_sdk2_python && pip install -e .

# conferir: tem que dar 3.1.0
python -c "import pinocchio; print(pinocchio.__version__)"
```

Certificado (README, 1.1):

```bash
cd ~/git_projects/xr_teleoperate/teleop/televuer
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem
mkdir -p ~/.config/xr_teleoperate && cp cert.pem key.pem ~/.config/xr_teleoperate/
sudo ufw allow 8012
```

Chave SSH no PC2:

```bash
ssh-copy-id unitree@192.168.123.164
```

### PC2

Já vem configurado: o teleimager fica em `~/unitree_eai_environment/service/teleimager` (env conda `tv` do PC2) e o servidor BrainCo em `~/unitree_eai_environment/service/brainco_hand_service/bin`.

## Antes de começar

- Bateria do robô acima de 50%; PICO e controles carregados.
- Robô no **modo ai** (braços rígidos).
- Área livre: ninguém ao alcance dos braços.
- Adaptador Ethernet ligado: `ping 192.168.123.164` tem que responder.
- PICO na mesma rede Wi-Fi do notebook.

## Rodar

```bash
~/git_projects/xr_teleoperate/teleop/run_g1d_tmux.sh
```

O script abre a sessão tmux `g1teleop` com três painéis:

| Painel | O que roda |
|---|---|
| Esquerda | teleop: espera o PC2 ficar pronto, ativa o `tv` e roda `teleop_hand_and_arm.py` |
| Direita, em cima | PC2: `sudo systemctl stop fatigue.service` e o servidor BrainCo |
| Direita, embaixo | PC2: `teleimager.image_server` |

Passo a passo:

1. Digite a senha do sudo do PC2 no painel de cima (o foco já está nele).
2. Espere. O teleop só inicia depois que o `fatigue.service` parar (até ~90 s) e a câmera responder.
   **Ao iniciar, os braços vão para a pose zero.**
3. Espere a mensagem `Press [r] to start syncing the robot with your movements`. **Ainda não aperte r.**
4. No PICO: **feche qualquer aba antiga** e abra uma nova em
   `https://192.168.10.123:8012/?ws=wss://192.168.10.123:8012`.
   Se aparecer o aviso de certificado, escolha **Advanced → Proceed**.
   Se a página abrir mas o websocket não ligar, use `https://vuer.ai?ws=wss://192.168.10.123:8012`.
5. Espere o vídeo aparecer e aperte **Virtual Reality**.
6. Fique na pose do robô: braços junto ao corpo, cotovelos a 90°, antebraços para a frente, controles como se fossem as mãos. Olhe para frente.
7. Clique no **painel esquerdo** do tmux e aperte **r**. Deve aparecer `🚀start Tracking🚀`. Comece com movimentos lentos.

### Controles

| Entrada | Efeito |
|---|---|
| Posição e rotação dos controles | movem os pulsos (IK dos braços) |
| Gatilho | fecha a mão BrainCo |
| Joysticks | nada (debug mode) |
| `r` / `q` (painel esquerdo) | começar a seguir / sair (braços voltam à pose zero em ~5 s) |
| Emergência | `Ctrl+C` no painel esquerdo, ou o controle R3 |

## Desligar

1. `q` no painel esquerdo (volte antes à pose inicial).
2. `Ctrl+C` nos dois painéis da direita.
3. `tmux kill-session -t g1teleop`
4. Robô: reative o modo ai no R3, ou reinicie o robô. O `fatigue.service` volta sozinho no boot.
5. Desligue o adaptador Ethernet.

## Problemas conhecidos

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| Braços sobem e ficam esticados depois do `r` | Aba do PICO da sessão anterior ainda aberta/em VR | `q`, feche a aba, abra uma nova, entre em VR, fique na pose, `r` |
| Vídeo aparece, braços não seguem | Não entrou em VR ou não apertou `r` com o foco no painel esquerdo | Virtual Reality e depois `r` |
| `AssertionError: Websocket session is missing` | A página recarregou e o vuer tentou mandar um frame para a sessão antiga | Inofensivo |
| PICO: "Unable to connect" | teleop não está rodando ou firewall | rode o teleop; `sudo ufw allow 8012` |
| teleop falha pedindo a configuração da câmera | teleimager não está rodando | ver painel de baixo |
| `Permission denied (publickey,password)` | chave SSH fora do PC2 | `ssh-copy-id unitree@192.168.123.164` |
| `externally-managed-environment` no `pip` | `tv` não está ativo | `micromamba activate tv` (prompt tem que mostrar `(tv)` e Python 3.10) |
| `Corrupt JPEG data` no painel da câmera | frames corrompidos da câmera UVC | ignorar, se for pontual |
| Com `--motion` os braços não se mexem | o G1-D ignora o `rt/arm_sdk` | usar debug mode |

Não rode o `test_brainco_hand_server` no PC2: ele abre e fecha as mãos em ciclo.
