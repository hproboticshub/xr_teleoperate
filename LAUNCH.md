# Como rodar a teleoperação do G1 (PICO + mãos BrainCo)

Guia rápido para o dia a dia. Instalação e detalhes estão no [README](README.md).

## Antes de começar

- O robô está ligado e o cabo de rede do PC está ligado ao robô. Qualquer
  adaptador serve: o script detecta sozinho a interface da rede `192.168.123.x`.
- A PICO e o PC estão na **mesma rede Wi-Fi**.

## 1. Iniciar no PC

Abra um terminal:

```bash
cd xr_teleoperate
conda activate tv
scripts/run_g1_teleop.sh --ee=brainco --input-mode=controller
```

O script:

1. entra por ssh na Jetson (PC2, `g1-jetson`). Se pedir a senha, a padrão
   da Unitree é `123`;
2. inicia o servidor de imagem da câmera da cabeça e espera ele responder;
3. escolhe a interface de rede do robô e arranca a teleoperação.

Quando aparecer `Press [r] to start syncing the robot with your movements`,
o PC está pronto. **Ainda não aperte `r`.**

## 2. Conectar na PICO

1. Descubra o IP do PC na rede Wi-Fi (a mesma da PICO):

   ```bash
   hostname -I
   ```

   Use o endereço da rede da PICO, por exemplo `192.168.10.171`, e não o
   `192.168.123.x` do robô.

2. No navegador da PICO, abra:

   ```
   https://<IP_DO_PC>:8012/?ws=wss://<IP_DO_PC>:8012
   ```

   Exemplo: `https://192.168.10.171:8012/?ws=wss://192.168.10.171:8012`

   O certificado é autoassinado: aceite o aviso ("Avançado" → "Continuar").

3. Confira se a imagem da câmera do robô aparece.
4. Clique em **Virtual Reality** para entrar no modo VR.

## 3. Começar a teleoperação

No terminal do PC:

- `r` → começa a sincronizar o robô com os seus movimentos;
- `q` → para e sai.

> ⚠️ Mantenha distância do robô enquanto ele estiver sendo teleoperado.

## Outras opções do script

```bash
scripts/run_g1_teleop.sh --ee=brainco --input-mode=controller --record   # gravar episódios
scripts/run_g1_teleop.sh --restart-server ...                            # reiniciar o servidor de imagem
scripts/run_g1_teleop.sh --stop-server                                   # parar o servidor e devolver a câmera à Unitree
```

## Problemas comuns

### BrainCo fica em `Waiting to subscribe dds...`

O serviço das mãos BrainCo no PC2 parou de publicar. Reinicie-o:

```bash
ssh g1-jetson
systemctl list-units --type=service --all | grep -i brainco   # mostra o nome do serviço
sudo systemctl restart <nome-do-serviço-brainco>
```

Depois rode o script de novo.

### Fica parado em `Connecting to g1-jetson ...` ou não consegue fazer ssh

- Teste se o robô responde: `ping 192.168.123.164`.
- Teste o ssh à mão: `ssh g1-jetson`.
- Se o alias `g1-jetson` não existir nesta máquina, o script usa
  `unitree@192.168.123.164`. Para forçar outro host:
  `G1_SSH_HOST=unitree@192.168.123.164 scripts/run_g1_teleop.sh ...`.

### `No interface on 192.168.123.x found`

O PC não tem IP na rede do robô. Verifique o cabo e configure o adaptador com
um IP fixo `192.168.123.x` (por exemplo `192.168.123.222/24`). Também dá para
forçar a interface: `--network-interface <nome>` (veja os nomes com `ip -br addr`).

### Não aparece imagem na PICO

- Reinicie o servidor de imagem: `scripts/run_g1_teleop.sh --restart-server --ee=brainco --input-mode=controller`.
- Veja o log no PC2: `ssh g1-jetson tail -n 80 /tmp/teleimager.log`.

### A página não abre na PICO

- Confirme que usou o IP do PC na rede Wi-Fi e `https://` (não `http://`).
- Se a porta estiver bloqueada pelo firewall do PC: `sudo ufw allow 8012`.
