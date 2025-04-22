#!/bin/bash

# エラー発生時や未定義変数使用時にスクリプトを終了する
set -eu
set -o pipefail

# --- 関数定義 ---
log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
}

# コマンド実行とエラーチェック
run_command() {
    log_info "Executing: $*"
    if ! "$@"; then
        log_error "Command failed: $*"
        exit 1
    fi
}

# 依存コマンドの存在チェック
check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        log_error "Required command '$1' is not installed. Please install it first."
        exit 1
    fi
}

# --- メイン処理 ---
main() {
    log_info "Starting Docker installation script..."

    # --- 0. 事前チェック ---
    log_info "Checking prerequisites..."
    # root権限確認
    if [ "$(id -u)" -ne 0 ]; then
       log_error "This script must be run as root or with sudo."
       exit 1
    fi
    # 必要なコマンドの確認
    check_command "apt-get"
    check_command "curl"
    check_command "gpg"
    check_command "dpkg"
    check_command "tee"
    check_command "chmod"
    check_command "install"
    check_command "grep"
    check_command "cut"

    # --- 1. 既存のDocker関連パッケージの削除 ---
    log_info "Removing old Docker packages if they exist..."
    OLD_PACKAGES="docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
    packages_to_remove=""
    for pkg in $OLD_PACKAGES; do
        # dpkg-queryでパッケージがインストールされているか確認
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            log_info "Found installed package: $pkg"
            packages_to_remove="$packages_to_remove $pkg"
        else
             log_info "Package '$pkg' not installed, skipping removal."
        fi
    done

    if [ -n "$packages_to_remove" ]; then
        run_command sudo apt-get remove -y $packages_to_remove
        run_command sudo apt-get autoremove -y # 不要な依存関係も削除
        run_command sudo apt-get purge -y $packages_to_remove # 設定ファイルも削除する場合
        log_info "Successfully removed old packages."
    else
        log_info "No old packages found to remove."
    fi


    # --- 2. リポジトリ設定に必要なパッケージのインストール ---
    log_info "Updating package list and installing necessary packages..."
    run_command sudo apt-get update
    run_command sudo apt-get install -y ca-certificates curl

    # --- 3. Docker公式GPGキーの追加 ---
    log_info "Adding Docker's official GPG key..."
    KEYRING_DIR="/etc/apt/keyrings"
    KEYRING_PATH="$KEYRING_DIR/docker.asc"
    run_command sudo install -m 0755 -d "$KEYRING_DIR"
    # curlでGPGキーをダウンロードし、ファイルに保存
    # 一時ファイルを経由してアトミックに書き込む方がより安全
    TEMP_KEY=$(mktemp)
    run_command curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TEMP_KEY"
    # ダウンロードしたキーがGPGキーとして有効か簡易チェック (オプション)
    if ! gpg --dearmor --output /dev/null "$TEMP_KEY"; then
        log_error "Downloaded file does not appear to be a valid GPG key."
        rm -f "$TEMP_KEY"
        exit 1
    fi
    run_command sudo mv "$TEMP_KEY" "$KEYRING_PATH"
    run_command sudo chmod a+r "$KEYRING_PATH"
    log_info "GPG key added to $KEYRING_PATH"

    # --- 4. Dockerリポジトリの追加 ---
    log_info "Setting up the Docker repository..."
    # アーキテクチャを取得
    ARCH=$(dpkg --print-architecture)
    if [ -z "$ARCH" ]; then
        log_error "Failed to determine system architecture using dpkg."
        exit 1
    fi
    log_info "Detected architecture: $ARCH"

    # OSコードネームを取得 (/etc/os-releaseが存在するか確認)
    OS_RELEASE_FILE="/etc/os-release"
    if [ ! -f "$OS_RELEASE_FILE" ]; then
        log_error "$OS_RELEASE_FILE not found. Cannot determine OS codename."
        exit 1
    fi
    # sourceではなくgrepとcutで安全に取得
    OS_CODENAME=$(grep '^UBUNTU_CODENAME=' $OS_RELEASE_FILE | cut -d'=' -f2)
    if [ -z "$OS_CODENAME" ]; then
        # UBUNTU_CODENAMEがない場合、VERSION_CODENAMEを試す (Debian系など)
        OS_CODENAME=$(grep '^VERSION_CODENAME=' $OS_RELEASE_FILE | cut -d'=' -f2)
    fi
    if [ -z "$OS_CODENAME" ]; then
        log_error "Failed to determine OS codename from $OS_RELEASE_FILE."
        exit 1
    fi
    log_info "Detected OS codename: $OS_CODENAME"

    # リポジトリ情報をsources.list.dに書き込む
    REPO_LIST_FILE="/etc/apt/sources.list.d/docker.list"
    REPO_STRING="deb [arch=$ARCH signed-by=$KEYRING_PATH] https://download.docker.com/linux/ubuntu $OS_CODENAME stable"
    log_info "Adding repository string to $REPO_LIST_FILE: $REPO_STRING"
    echo "$REPO_STRING" | run_command sudo tee "$REPO_LIST_FILE" > /dev/null

    # --- 5. Dockerエンジンのインストール ---
    log_info "Updating package list again after adding Docker repository..."
    run_command sudo apt-get update

    log_info "Installing Docker Engine, CLI, containerd, and plugins..."
    DOCKER_PACKAGES="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    run_command sudo apt-get install -y $DOCKER_PACKAGES

    # --- 6. インストール確認 (任意) ---
    log_info "Verifying Docker installation..."
    if ! run_command sudo docker run hello-world; then
        log_error "Docker installation verification failed. 'docker run hello-world' did not succeed."
        log_info "You might need to add your user to the 'docker' group:"
        log_info "  sudo usermod -aG docker \$USER"
        log_info "Then log out and log back in, or run 'newgrp docker'."
        exit 1 # 検証失敗はエラーとして扱う場合
    fi

    # --- 完了 ---
    log_info "Docker installation completed successfully!"
    log_info "You may need to add your user to the 'docker' group to run Docker commands without sudo:"
    log_info "  sudo usermod -aG docker \$USER"
    log_info "After running the command, log out and log back in for the changes to take effect, or run 'newgrp docker'."

    exit 0
}

# スクリプト実行
main "$@"