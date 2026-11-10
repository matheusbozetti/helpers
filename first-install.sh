#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
	echo "Não rode como root/sudo. O script pede sudo quando necessário."
	exit 1
fi

NODE_VERSION="26"
NVM_VERSION="v0.41.0"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Proxy corporativo (inspeção TLS) reassina o HTTPS com uma CA própria, que está no
# repositório do sistema. Node, Python (httpie/pip) e AWS CLI usam bundles próprios,
# então apontamos todos para o bundle do sistema.
SYSTEM_CA="/etc/ssl/certs/ca-certificates.crt"
export NODE_EXTRA_CA_CERTS="$SYSTEM_CA"
export REQUESTS_CA_BUNDLE="$SYSTEM_CA"
export SSL_CERT_FILE="$SYSTEM_CA"
export AWS_CA_BUNDLE="$SYSTEM_CA"
mkdir -p "$HOME/.config/environment.d"
cat >"$HOME/.config/environment.d/10-system-ca.conf" <<EOF
NODE_EXTRA_CA_CERTS=$SYSTEM_CA
REQUESTS_CA_BUNDLE=$SYSTEM_CA
SSL_CERT_FILE=$SYSTEM_CA
AWS_CA_BUNDLE=$SYSTEM_CA
EOF

run_quiet_on_success() {
	local output
	if ! output=$(eval "$*" 2>&1); then
		echo "Erro detectado em: $*"
		echo "$output"
		return 1
	fi
}

APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

wait_for_dpkg_lock() {
	while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
		echo "   Aguardando outro processo liberar o apt/dpkg (atualizações automáticas)..."
		sleep 10
	done
}

apt_install() {
	run_quiet_on_success "$APT install -y $*"
}

deb_install() {
	local url="$1"
	local file
	file="$(mktemp --suffix=.deb)"
	curl -fsSL "$url" -o "$file"
	chmod 644 "$file"
	run_quiet_on_success "$APT install -y $file"
	rm -f "$file"
}

snap_install() {
	run_quiet_on_success "sudo snap install $*"
}

curl() {
	command curl --retry 5 --retry-delay 3 --retry-all-errors "$@"
}

has() { command -v "$1" >/dev/null 2>&1; }
deb_has() { dpkg -s "$1" >/dev/null 2>&1; }
snap_has() { snap list "$1" >/dev/null 2>&1; }
fc_has_hack() { fc-list 2>/dev/null | grep -q "Hack Nerd Font"; }

# Rode com FORCE=1 para reinstalar tudo mesmo que já exista.
already() {
	if [ "${FORCE:-0}" != "1" ] && "$@"; then
		echo "   Já instalado, pulando."
		return 0
	fi
	return 1
}

github_latest_tag() {
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -Po '"tag_name":\s*"\K[^"]+'
}

set_us_keyboard() {
	read -r -p "   Usar teclado americano (US International) como padrão? [y/N] " answer
	if [[ "$answer" =~ ^[Yy]$ ]]; then
		gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us+intl')]"
		echo "    Teclado americano configurado como padrão."
	else
		echo "    Teclado não alterado"
	fi
}

# Pede a senha do sudo uma vez no início
sudo -v

echo "----> APT update/upgrade"
wait_for_dpkg_lock
# Conclui instalações interrompidas (comum em máquina nova após atualização automática)
sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a
# Saída visível: numa máquina nova o primeiro upgrade leva vários minutos
$APT update -y
$APT upgrade -y

echo "----> Installing base tools (git, curl, wget, gpg, unzip, build-essential)"
apt_install git curl wget gpg unzip ca-certificates build-essential

echo "----> Installing keyboard locales"
apt_install keyboard-configuration console-setup locales
set_us_keyboard

echo "----> Installing ZSH"
apt_install zsh
set_default_shell_zsh() {
	local zsh_path
	zsh_path="$(command -v zsh)"
	if [ "$(getent passwd "$USER" | cut -d: -f7)" = "$zsh_path" ]; then
		return 0
	fi
	if grep -q "^$USER:" /etc/passwd; then
		# Usuário local: chsh funciona normalmente
		sudo chsh -s "$zsh_path" "$USER"
	elif has sss_override && systemctl is-active --quiet sssd; then
		# Usuário de domínio (AD/LDAP via SSSD) não está em /etc/passwd e o chsh falha
		# ("user not found"). Sobrescreve o shell localmente pelo SSSD.
		sudo sss_override user-add "$USER" -s "$zsh_path"
		sudo systemctl restart sssd
	else
		# Último recurso: bash abre o zsh em sessões interativas
		echo "   Não foi possível alterar o shell padrão; usando 'exec zsh' no ~/.bashrc."
		if ! grep -q 'exec zsh' "$HOME/.bashrc" 2>/dev/null; then
			printf '\n# Abre o zsh (shell padrão não pôde ser alterado)\n[[ $- == *i* ]] && [ -x %s ] && exec %s\n' "$zsh_path" "$zsh_path" >>"$HOME/.bashrc"
		fi
	fi
}
set_default_shell_zsh

echo "----> Installing CLI tools (eza, bat, ripgrep, fd, zoxide, delta, dig, jq, httpie, mkcert)"
# Usados pelos aliases/fzf/git config do dev-env
apt_install eza bat ripgrep fd-find zoxide git-delta dnsutils jq httpie mkcert libnss3-tools fontconfig
# No Ubuntu os binários se chamam batcat e fdfind
ln -sf /usr/bin/batcat "$BIN_DIR/bat"
ln -sf /usr/bin/fdfind "$BIN_DIR/fd"

echo "----> Installing Hack Nerd Font"
FONT_DIR="$HOME/.local/share/fonts/HackNerdFont"
if ! already fc_has_hack; then
	NERD_FONTS_VERSION="$(github_latest_tag ryanoasis/nerd-fonts)"
	FONT_ZIP="$(mktemp --suffix=.zip)"
	curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/Hack.zip" -o "$FONT_ZIP"
	mkdir -p "$FONT_DIR"
	unzip -oq "$FONT_ZIP" -d "$FONT_DIR"
	rm -f "$FONT_ZIP"
	fc-cache -f >/dev/null
fi

echo "----> Installing VSCode"
# O .deb oficial também adiciona o repositório da Microsoft (atualizações via apt)
if ! already has code; then
	echo "code code/add-microsoft-repo boolean true" | sudo debconf-set-selections
	deb_install "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"
fi

echo "----> Installing DBGate"
if ! already deb_has dbgate; then
	deb_install "https://github.com/dbgate/dbgate/releases/latest/download/dbgate-latest.deb"
fi

echo "----> Installing Google Chrome"
# O pacote também adiciona o repositório apt do Google
if ! already has google-chrome-stable; then
	deb_install "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
fi

echo "----> Installing Bruno (API client)"
if ! already snap_has bruno; then
	snap_install bruno
fi

echo "----> Installing Discord"
# Snap (Snapcrafters, atualizado): o .deb de discord.com fica inacessível na rede corporativa
if ! already snap_has discord; then
	snap_install discord
fi

echo "----> Installing Starship"
if ! already has starship; then
	curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$BIN_DIR" >/dev/null
fi

echo "----> Installing Flameshot, tmux, lsd, fzf"
apt_install flameshot tmux lsd fzf

echo "----> Installing dust"
if ! already has dust; then
	curl -fsSL https://raw.githubusercontent.com/bootandy/dust/refs/heads/master/install.sh | bash
fi

echo "----> Installing Podman"
apt_install podman podman-compose podman-docker uidmap slirp4netns
# Silencia o aviso "Emulate Docker CLI using podman"
sudo touch /etc/containers/nodocker
# Socket compatível com a API do Docker (usado pelo lazydocker)
systemctl --user enable --now podman.socket
mkdir -p "$HOME/.config/environment.d"
echo 'DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock' >"$HOME/.config/environment.d/podman.conf"

echo "----> Installing lazygit"
if ! already has lazygit; then
	LAZYGIT_VERSION="$(github_latest_tag jesseduffield/lazygit)"
	LAZYGIT_TMP="$(mktemp -d)"
	curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION#v}_linux_x86_64.tar.gz" |
		tar -xz -C "$LAZYGIT_TMP" lazygit
	install -m 755 "$LAZYGIT_TMP/lazygit" "$BIN_DIR/lazygit"
	rm -rf "$LAZYGIT_TMP"
fi

echo "----> Installing lazydocker"
if ! already has lazydocker; then
	curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh |
		DIR="$BIN_DIR" bash >/dev/null
fi

echo "----> Installing NVM + Node $NODE_VERSION"
# Mesmo caminho que o .zshrc do dev-env carrega ($XDG_CONFIG_HOME/nvm)
export NVM_DIR="$HOME/.config/nvm"
mkdir -p "$NVM_DIR"
if ! already test -s "$NVM_DIR/nvm.sh"; then
	# PROFILE=/dev/null: o dev-env já cuida do carregamento do nvm no zsh
	curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | PROFILE=/dev/null bash >/dev/null
fi
# nvm não é compatível com "set -u"
set +u
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
# Se a versão já existir, o nvm só a ativa (não baixa de novo)
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use default
set -u

echo "----> Installing Corepack + PNPM"
# Node >= 25 não traz mais o corepack embutido
if ! already has corepack; then
	npm install -g corepack >/dev/null
fi
corepack enable
corepack enable pnpm
if ! already test -n "$(ls "${COREPACK_HOME:-$HOME/.cache/node/corepack}/v1/pnpm" 2>/dev/null)"; then
	COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack install -g pnpm@latest
fi

echo "----> Installing tree-sitter CLI"
# A versão do apt (0.20) não tem o "tree-sitter build" usado pelo nvim-treesitter,
# e /usr/bin vem antes de ~/.local/bin no PATH do dev-env: remove a do apt.
if dpkg -s tree-sitter-cli >/dev/null 2>&1; then
	run_quiet_on_success "$APT purge -y tree-sitter-cli"
fi
# Binário do GitHub (independe da versão do Node ativa no nvm)
if ! already test -x "$BIN_DIR/tree-sitter"; then
	TREE_SITTER_VERSION="$(github_latest_tag tree-sitter/tree-sitter)"
	curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-linux-x64.gz" |
		gunzip >"$BIN_DIR/tree-sitter.tmp"
	install -m 755 "$BIN_DIR/tree-sitter.tmp" "$BIN_DIR/tree-sitter"
	rm -f "$BIN_DIR/tree-sitter.tmp"
fi

echo "----> Installing Go"
# Necessário para o mason instalar o gopls; o PATH do dev-env já inclui /usr/local/go/bin
if ! already test -x /usr/local/go/bin/go; then
	GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
	curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
	sudo rm -rf /usr/local/go
	sudo tar -C /usr/local -xzf /tmp/go.tar.gz
	rm -f /tmp/go.tar.gz
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

echo "----> Installing air (Go live reload)"
# Vai para ~/go/bin, que já está no PATH do dev-env
if ! already has air; then
	go install github.com/air-verse/air@latest
fi

echo "----> Installing OpenVPN (NetworkManager GUI)"
# Integra ao menu de rede do GNOME (Configurações > Rede > VPN), substitui o OpenVPN Connect
apt_install openvpn network-manager-openvpn network-manager-openvpn-gnome
read -r -p "   Caminho de um perfil .ovpn para importar (Enter para pular): " OVPN_FILE
OVPN_FILE="${OVPN_FILE/#\~/$HOME}"
if [ -n "$OVPN_FILE" ] && [ -f "$OVPN_FILE" ]; then
	VPN_NAME="$(basename "$OVPN_FILE" .ovpn)"
	if nmcli -t -f NAME connection show | grep -qxF "$VPN_NAME"; then
		echo "   VPN \"$VPN_NAME\" já existe, pulando."
	else
		nmcli connection import type openvpn file "$OVPN_FILE" >/dev/null
		# OpenVPN 2.6 só negocia ciphers GCM por padrão; servidores (ex.: Pritunl)
		# com AES-*-CBC conectam mas caem/não trafegam. Libera os CBC como fallback.
		nmcli connection modify "$VPN_NAME" +vpn.data "data-ciphers=AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC"
		echo "   VPN \"$VPN_NAME\" importada. Conecte pelo menu de rede (canto superior direito)."
	fi
elif [ -n "$OVPN_FILE" ]; then
	echo "   Arquivo não encontrado: $OVPN_FILE (pulando)"
fi

echo "----> Raising inotify limits (file watchers: Vite, Next, tsc...)"
printf 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=1024\n' |
	sudo tee /etc/sysctl.d/99-dev.conf >/dev/null
run_quiet_on_success "sudo sysctl --system"

echo "----> Installing AWS CLI"
if ! already has aws; then
	curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash -s -- --quiet
fi

echo "----> Installing Ghostty terminal"
if ! already snap_has ghostty; then
	snap_install ghostty --classic
fi

echo "----> Installing dev-env"
mkdir -p "$HOME/Projects"
rm -rf "$HOME/Projects/dev-env"
git clone -q -b ubuntu https://github.com/matheusbozetti/dev.git "$HOME/Projects/dev-env"
# ./run compila o neovim (demorado): só roda se o nvim ainda não existir.
# ./dev-env (dotfiles) roda sempre, para manter as configs atualizadas.
if ! already has nvim; then
	(cd "$HOME/Projects/dev-env" && ./run)
fi
(cd "$HOME/Projects/dev-env" && ./dev-env)
rm -rf "$HOME/Projects/dev-env"

echo "----> Installing Claude Code"
if ! already has claude; then
	curl -fsSL https://claude.ai/install.sh | bash
fi

echo "----> Installing tmux plugins"
TPM_INSTALL="$HOME/.config/tmux/plugins/tpm/bin/install_plugins"
if [ -x "$TPM_INSTALL" ]; then
	"$TPM_INSTALL"
else
	echo "   TPM não encontrado em $TPM_INSTALL, pulando."
fi

echo "----> Installing mkcert local CA"
mkcert -install

echo "----> Configuring git identity"
# Em ~/.gitconfig porque ~/.config/git/config é sobrescrito pelo dev-env
GIT_NAME="$(git config --file "$HOME/.gitconfig" user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --file "$HOME/.gitconfig" user.email 2>/dev/null || true)"
if [ -z "$GIT_NAME" ]; then
	read -r -p "   Nome para o git: " GIT_NAME
	git config --file "$HOME/.gitconfig" user.name "$GIT_NAME"
fi
if [ -z "$GIT_EMAIL" ]; then
	read -r -p "   E-mail para o git/SSH: " GIT_EMAIL
	git config --file "$HOME/.gitconfig" user.email "$GIT_EMAIL"
fi

echo "----> Generating SSH key (RSA)"
# RSA porque o Azure DevOps só aceita chaves RSA
SSH_KEY="$HOME/.ssh/id_rsa"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ -f "$SSH_KEY" ]; then
	echo "   Chave $SSH_KEY já existe, mantendo a atual."
else
	ssh-keygen -t rsa -b 4096 -C "$GIT_EMAIL" -f "$SSH_KEY"
fi

echo
echo "================ CHAVE PÚBLICA ($SSH_KEY.pub) ================"
echo "   Cole esta chave no GitHub e no Azure DevOps:"
echo "   - GitHub:       https://github.com/settings/ssh/new"
echo "   - Azure DevOps: User settings > SSH public keys > + New Key"
echo
cat "$SSH_KEY.pub"
echo

echo
echo "================ VPN (OpenVPN/Pritunl) ================"
echo "   Se importar um .ovpn manualmente e a VPN conectar mas cair ou não trafegar,"
echo "   libere os ciphers CBC (troque <NOME_DA_VPN>; liste com: nmcli connection show):"
echo
echo '   nmcli connection modify "<NOME_DA_VPN>" +vpn.data "data-ciphers=AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC"'
echo
echo "   Depois desconecte e conecte novamente a VPN pelo menu de rede."

echo
echo "Instalação concluída! Faça logout/login (ou reinicie) para aplicar o ZSH e o DOCKER_HOST do Podman."
