#!/bin/bash
# ==============================================================================
# Ubuntu用 Docker Engine インストールスクリプト
#
# このスクリプトは、公式ドキュメントの手順に従って、Docker Engine、CLI、containerd、
# Docker Compose プラグインを Ubuntu システムにインストールします。
# エラーハンドリング、前提条件チェック、クリーンアップが含まれます。
#
# 使い方: sudo ./install_docker.sh
# ==============================================================================

# --- Strict Mode ---
# コマンドがゼロ以外のステータスで終了した場合、直ちに終了します。(set -e)
# 未定義の変数を展開しようとした場合、エラーとして扱います。(set -u)
# パイプラインの戻り値は、最後にゼロ以外のステータスで終了したコマンドのステータス、
# またはすべてのコマンドが成功した場合はゼロになります。(set -o pipefail)
set -euo pipefail

# --- 設定 / 定数 ---
# ログのタイムスタンプ形式
readonly LOG_DATE_FORMAT='+%Y-%m-%d %H:%M:%S'

# このスクリプトが実行開始時に必要とするコマンドのリスト
readonly REQUIRED_COMMANDS=(apt-get curl gpg dpkg tee chmod install grep cut mktemp)

# 削除対象の古いDockerパッケージリスト
readonly OLD_DOCKER_PACKAGES="docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"

# Docker公式GPGキーのURL
readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"

# Docker GPGキーを格納するディレクトリとファイル名
readonly KEYRING_DIR="/etc/apt/keyrings"
readonly KEYRING_FILENAME="docker.asc"

# Docker APTリポジトリリストのディレクトリとファイル名
readonly APT_SOURCES_DIR="/etc/apt/sources.list.d"
readonly REPO_LIST_FILENAME="docker.list"

# OSコードネームを特定するためのos-releaseファイルのパス
readonly OS_RELEASE_FILE="/etc/os-release"

# インストールするDockerパッケージのリスト
readonly DOCKER_PACKAGES_TO_INSTALL="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# インストール検証に使用するイメージ名
readonly VERIFICATION_IMAGE="hello-world"


# --- ログ出力関数 ---

# 情報メッセージをタイムスタンプ付きでログに出力します。
# 使い方: log_info "メッセージ内容"
log_info() {
    echo "[INFO] $(date +"$LOG_DATE_FORMAT") - $1"
}

# エラーメッセージをタイムスタンプ付きで標準エラー出力に出力します。
# 使い方: log_error "エラーメッセージ内容"
log_error() {
    # 標準エラー出力へ出力
    echo "[ERROR] $(date +"$LOG_DATE_FORMAT") - $1" >&2
}


# --- ヘルパー関数 ---

# コマンドを実行し、失敗した場合はスクリプトを終了します。
# 実行するコマンドをログに出力します。
# 使い方: run_command <command> [arguments...]
run_command() {
    log_info "実行中: $*"
    # 引数を正しく保持してコマンドを実行
    if ! "$@"; then
        # $? で直前のコマンドの終了ステータスを取得
        log_error "コマンドがステータス $? で失敗しました: $*"
        exit 1
    fi
}

# 必須コマンドがシステムのPATHに存在するか確認します。
# コマンドが見つからない場合はスクリプトを終了します。
# 使い方: check_command <コマンド名>
check_command() {
    local cmd="$1"
    # command -v でコマンドが存在し実行可能か確認
    if ! command -v "$cmd" > /dev/null 2>&1; then
        log_error "必須コマンド '$cmd' がインストールされていないか、PATHに含まれていません。先にインストールしてください。"
        exit 1
    fi
}


# --- インストールステップ関数 ---

# スクリプトの前提条件を確認します: root権限と必須コマンド。
check_prerequisites() {
    log_info "フェーズ 0: 前提条件の確認..."

    # root権限の確認
    if [ "$(id -u)" -ne 0 ]; then
       log_error "このスクリプトはroot権限またはsudoで実行する必要があります。"
       exit 1
    fi
    log_info "root権限を確認しました。"

    # 必須コマンドの確認
    log_info "必要なコマンドラインツールの確認..."
    # REQUIRED_COMMANDS 配列の全要素をチェック
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        check_command "$cmd"
    done
    log_info "必要なツールがすべて存在します。"
}

# 古いバージョンのDockerおよび関連パッケージを削除します。
remove_old_docker() {
    log_info "フェーズ 1: 競合する可能性のある古いDockerパッケージの削除..."

    local packages_to_remove=""
    # 古いパッケージのリストを反復処理
    for pkg in $OLD_DOCKER_PACKAGES; do
        # パッケージが現在インストールされているか確認
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            log_info "インストール済みの競合パッケージを発見: $pkg"
            packages_to_remove="$packages_to_remove $pkg"
        else
             log_info "パッケージ '$pkg' はインストールされていません。スキップします。"
        fi
    done

    # 競合パッケージが見つかった場合は削除
    if [ -n "$packages_to_remove" ]; then
        run_command apt-get remove -y $packages_to_remove
        run_command apt-get autoremove -y
        log_info "古いDockerパッケージと依存関係を正常に削除しました。"
    else
        log_info "競合する古いDockerパッケージは見つかりませんでした。"
    fi
}

# Dockerリポジトリの設定に必要なパッケージをインストールします。
install_repository_prerequisites() {
    log_info "フェーズ 2: Dockerリポジトリ設定に必要なパッケージのインストール..."

    run_command apt-get update
    run_command apt-get install -y ca-certificates curl
    log_info "リポジトリ設定の前提パッケージを正常にインストールしました。"
}

# Dockerの公式GPGキーをダウンロード、検証、インストールします。
setup_docker_gpg_key() {
    log_info "フェーズ 3: Docker公式GPGキーの追加..."

    local keyring_path="$KEYRING_DIR/$KEYRING_FILENAME"

    run_command install -m 0755 -d "$KEYRING_DIR"

    local temp_key
    temp_key=$(mktemp)
    log_info "GPGキーを $DOCKER_GPG_URL から $temp_key へダウンロード中..."
    run_command curl -fsSL "$DOCKER_GPG_URL" -o "$temp_key"

    log_info "ダウンロードしたGPGキーを検証中..."
    if ! gpg --dearmor --output /dev/null "$temp_key"; then
        log_error "ダウンロードしたファイル ($temp_key) は有効なGPGキーではないようです。"
        rm -f "$temp_key"
        exit 1
    fi
    log_info "GPGキーの検証に成功しました。"

    run_command mv "$temp_key" "$keyring_path"
    run_command chmod a+r "$keyring_path"
    log_info "Docker GPGキーを $keyring_path に正常に追加しました。"
}

# Docker APTリポジトリをシステムのソースリストに設定します。
setup_docker_repository() {
    log_info "フェーズ 4: Docker APTリポジトリの設定..."

    local keyring_path="$KEYRING_DIR/$KEYRING_FILENAME"
    local repo_list_path="$APT_SOURCES_DIR/$REPO_LIST_FILENAME"

    local arch
    arch=$(dpkg --print-architecture)
    if [ -z "$arch" ]; then
        log_error "dpkg を使用してシステムアーキテクチャを特定できませんでした。"
        exit 1
    fi
    log_info "検出されたシステムアーキテクチャ: $arch"

    if [ ! -f "$OS_RELEASE_FILE" ]; then
        log_error "$OS_RELEASE_FILE が見つかりません。OSコードネームを特定できません。"
        exit 1
    fi
    local os_codename
    os_codename=$(grep '^UBUNTU_CODENAME=' "$OS_RELEASE_FILE" | cut -d'=' -f2)
    if [ -z "$os_codename" ]; then
        os_codename=$(grep '^VERSION_CODENAME=' "$OS_RELEASE_FILE" | cut -d'=' -f2)
    fi
    if [ -z "$os_codename" ]; then
        log_error "$OS_RELEASE_FILE からOSコードネームを特定できませんでした。"
        exit 1
    fi
    log_info "検出されたOSコードネーム: $os_codename"

    local repo_string="deb [arch=$arch signed-by=$keyring_path] https://download.docker.com/linux/ubuntu $os_codename stable"

    log_info "リポジトリ情報を $repo_list_path へ追加: $repo_string"
    echo "$repo_string" | run_command tee "$repo_list_path" > /dev/null
    log_info "Docker APTリポジトリを正常に追加しました。"
}

# Docker Engineおよび関連パッケージをインストールします。
install_docker_engine() {
    log_info "フェーズ 5: Docker Engineのインストール..."

    log_info "Dockerリポジトリ追加後にパッケージリストを更新中..."
    run_command apt-get update

    log_info "Dockerパッケージをインストール中: $DOCKER_PACKAGES_TO_INSTALL"
    run_command apt-get install -y $DOCKER_PACKAGES_TO_INSTALL

    # 'docker' コマンドが利用可能になったか確認
    check_command "docker"
    log_info "Docker Engineを正常にインストールしました。"
}

# hello-worldコンテナを実行してDockerのインストールを検証します。
verify_installation() {
    log_info "フェーズ 6: Dockerインストールの検証..."

    log_info "'$VERIFICATION_IMAGE' コンテナの実行を試みます..."
    if ! run_command docker run "$VERIFICATION_IMAGE"; then
        log_error "Dockerインストールの検証に失敗しました。'$VERIFICATION_IMAGE' コンテナが正常に実行されませんでした。"
        print_post_installation_notes
        exit 1
    fi
    log_info "Dockerインストールを '$VERIFICATION_IMAGE' の実行により正常に検証しました。"
}

# インストール検証に使用したコンテナとイメージを削除します。
cleanup_verification_artifacts() {
    log_info "フェーズ 7: 検証用アーティファクトのクリーンアップ..."

    log_info "'$VERIFICATION_IMAGE' イメージに基づくコンテナを検索中..."
    local verification_containers
    verification_containers=$(docker ps -aq --filter "ancestor=$VERIFICATION_IMAGE")

    if [ -n "$verification_containers" ]; then
        log_info "削除対象のコンテナを発見: $verification_containers"
        echo "$verification_containers" | xargs --no-run-if-empty docker rm
        local cleanup_status="${PIPESTATUS[1]}"
        if [ "$cleanup_status" -ne 0 ]; then
            log_error "'$VERIFICATION_IMAGE' コンテナの削除に失敗しました (ステータス $cleanup_status)。"
            # エラーでも続行
        else
            log_info "検証用コンテナを正常に削除しました。"
        fi
    else
        log_info "'$VERIFICATION_IMAGE' コンテナは見つかりませんでした。"
    fi

    log_info "'$VERIFICATION_IMAGE' イメージの削除を試みます..."
    if docker image inspect "$VERIFICATION_IMAGE" > /dev/null 2>&1; then
        run_command docker image rm "$VERIFICATION_IMAGE"
        log_info "'$VERIFICATION_IMAGE' イメージを正常に削除しました。"
    else
        log_info "'$VERIFICATION_IMAGE' イメージはローカルに見つかりません。削除をスキップします。"
    fi

    log_info "検証用アーティファクトのクリーンアップが完了しました。"
}

# インストール成功後、ユーザーへの最終的な注意事項を表示します。
print_post_installation_notes() {
    log_info "--------------------------------------------------"
    log_info "Dockerのインストールが正常に完了しました！"
    log_info "--------------------------------------------------"
    log_info "インストール後の作業:"
    log_info " root以外のユーザーでDockerコマンドを実行するには、ユーザーを'docker'グループに追加してください:"
    log_info "   sudo usermod -aG docker \$USER"
    log_info " 注意: 上記コマンド実行後、変更を有効にするにはログアウトして再ログインするか、"
    log_info "       現在のシェルで 'newgrp docker' を実行する必要があります。"
    log_info "--------------------------------------------------"
}


# --- メイン実行ロジック ---

# インストール手順を統括するメイン関数。
main() {
    log_info "=== Dockerインストール開始 ==="

    # ステップ 0: 前提条件の確認
    check_prerequisites

    # ステップ 1: 古いDockerバージョンの削除
    remove_old_docker

    # ステップ 2: リポジトリ設定の前提パッケージインストール
    install_repository_prerequisites

    # ステップ 3: Docker GPGキーの追加
    setup_docker_gpg_key

    # ステップ 4: Dockerリポジトリの設定
    setup_docker_repository

    # ステップ 5: Docker Engineのインストール
    install_docker_engine

    # ステップ 6: インストールの検証
    verify_installation

    # ステップ 7: 検証用アーティファクトのクリーンアップ
    cleanup_verification_artifacts

    # ステップ 8: 完了メッセージの表示
    print_post_installation_notes

    log_info "=== Dockerインストール正常終了 ==="
    exit 0
}

# --- スクリプトエントリポイント ---
# main関数を呼び出し、スクリプト引数（現在は未使用）を渡します。
main "$@"