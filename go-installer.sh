#!/bin/bash
# goInstaller — Copyright (c) 2026 anten-ka. All rights reserved.
#
# Единый установщик продуктов серии go: goVLESS pro, goTelegram pro,
# goDNS pro, goKaskad pro, goWARP pro, goAmnezia pro. Сам ничего не настраивает — проверяет машину,
# порты и соседей ДО запуска штатного установщика продукта, а потом отдаёт
# управление ему. Каждый продукт ставится своим собственным кодом.
#
#   GH_TOKEN=<ключ на чтение> bash go-installer.sh
#   bash go-installer.sh --list              # что установлено
#
# После первого запуска доступна команда `goinstall`. Ключ доступа хранится
# в /opt/go-installer/token (0600) и проверяется при каждом запуске запросом
# к репозиториям продуктов; не подошёл — установщик попросит новый.
#   bash go-installer.sh --ports             # кто какие порты держит
#   bash go-installer.sh --check govless pro # проверка портов без установки
#   bash go-installer.sh --install godns     # сразу к установке продукта
#
# Один ключ на все закрытые репозитории: GH_TOKEN (принимаются также
# GOTELEGRAM_PAT, GITHUB_PAT, GOINST_TOKEN). В аргументы curl ключ не
# попадает: /proc/<pid>/cmdline читает любой локальный пользователь.
#
# Локальное дерево вместо GitHub: GOINST_SRC_<id>=/путь, где id — один из
# govless gotelegram godns gokaskad gowarp. Ветка: GOINST_REF_<id>.

set -uo pipefail

GOINST_VERSION="1.2.6"
GOINST_DIR="${GOINST_DIR:-/opt/go-installer}"
GOINST_BIN="${GOINST_BIN:-/usr/local/bin/goinstall}"
GOINST_BIN_ALIAS="${GOINST_BIN_ALIAS:-/usr/local/bin/go-installer}"
GOINST_SELF_REPO="${GOINST_SELF_REPO:-anten-ka/goInstaller}"
GOINST_SELF_REF="${GOINST_SELF_REF:-main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

PRODUCTS=(govless gotelegram godns gokaskad gowarp goamnezia)

# ── язык ────────────────────────────────────────────────────────────────
# Установщик работает раньше любого продукта, своей таблицы строк у него
# нет — две фразы рядом. Порядок: маркер соседа → локаль → русский.
# Файл, где запомнен язык, выбранный в самом goInstaller.
lang_file() { printf '%s' "${GOINST_LANG_FILE:-${GOINST_DIR}/.language}"; }

# _lang_marker <файл> — «ru» или «en» из маркера языка, иначе rc 1.
_lang_marker() {
    local v=""
    [ -r "$1" ] || return 1
    IFS= read -r v < "$1" 2>/dev/null || true
    case "$v" in
        ru*) printf 'ru' ;;
        en*) printf 'en' ;;
        *) return 1 ;;
    esac
}

# Язык, который оператор уже выбрал в соседнем продукте на этой машине.
# goAmnezia пишет такой же маркер; пока его не читали, выбор, сделанный в
# нём, установщик не видел.
lang_neighbour() {
    local r="${GOINST_FS_ROOT:-}" f
    for f in "$r/opt/godns/.language" "$r/opt/govless/.language" \
             "$r/opt/gotelegram/.language" "$r/opt/goamnezia/.language"; do
        _lang_marker "$f" && return 0
    done
    return 1
}

# Язык без вопроса: для справочных команд и запусков без терминала. Меню и
# установка спрашивают его сами первым экраном, см. lang_startup.
_pick_lang() {
    _lang_marker "$(lang_file)" && return 0
    lang_neighbour && return 0
    case "${LC_ALL:-${LANG:-}}" in
        ru*|RU*) printf 'ru'; return 0 ;;
        en*|EN*|C.*|C|POSIX) printf 'en'; return 0 ;;
    esac
    printf 'ru'
}
LANG_CODE="${GOINST_LANG:-$(_pick_lang)}"
bi() { if [ "$LANG_CODE" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Наличие команды; GOINST_FAKE_CMDS="warp-cli" — подмена для тестов.
have_cmd() {
    if [ -n "${GOINST_FAKE_CMDS+x}" ]; then
        case " ${GOINST_FAKE_CMDS} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
    fi
    command -v "$1" >/dev/null 2>&1
}

# PF_CAPTURE — проверка портов идёт для экрана «Аркады»: сообщения правил
# соседства ещё и складываются в PF_MSGS, экран покажет их сам.
say()  { [ -n "${PF_CAPTURE:-}" ] && PF_MSGS+=("i|$*"); echo -e "  ${CYAN}ℹ${NC}  $*" >&2; }
ok()   { [ -n "${PF_CAPTURE:-}" ] && PF_MSGS+=("o|$*"); echo -e "  ${GREEN}✓${NC}  $*" >&2; }
warn() { [ -n "${PF_CAPTURE:-}" ] && PF_MSGS+=("w|$*"); echo -e "  ${YELLOW}!${NC}  $*" >&2; }
err()  { [ -n "${PF_CAPTURE:-}" ] && PF_MSGS+=("e|$*"); echo -e "  ${RED}✗${NC}  $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { echo -e "  ${DIM}$(printf '─%.0s' {1..60})${NC}"; }

print_header() {
    echo "" >&2
    echo -e "  ${CYAN}${BOLD}$1${NC}" >&2
    hr >&2
}

# Enter и Ctrl-D — разные ответы. Код 0 и пустая строка — Enter (умолчание),
# код 1 при пустой переменной — отмена. Код 1 с непустой — тоже ответ
# (строка без перевода строки).
read_line() {
    local __var="$1" __prompt="${2:-  ▸ }" __v=""
    if IFS= read -rp "$__prompt" __v; then
        printf -v "$__var" '%s' "$__v"; return 0
    fi
    printf -v "$__var" '%s' "$__v"
    [ -n "$__v" ] && return 0
    echo ""; return 1
}

# confirm <вопрос> <умолчание y|n>
#
# Ответы ТОЛЬКО цифрами: 1 — да, 2 — нет. Буквенное «[Y/n]» на русской
# раскладке требует переключения ради одного символа, а в остальных
# вопросах установщика и так жмут цифры — две разные привычки в одном
# разговоре человек не держит.
confirm() {
    local q="$1" def="${2:-n}" ans tries=0 mark_yes="" mark_no=""
    if [ "$def" = "y" ]; then mark_yes=" ${DIM}— $(bi "по умолчанию" "default")${NC}"
    else mark_no=" ${DIM}— $(bi "по умолчанию" "default")${NC}"; fi
    while [ "$tries" -lt 3 ]; do
        tries=$((tries+1))
        echo "" >&2
        echo -e "  $q" >&2
        echo -e "  ${CYAN}1)${NC} $(bi "Да" "Yes")${mark_yes}" >&2
        echo -e "  ${CYAN}2)${NC} $(bi "Нет" "No")${mark_no}" >&2
        read_line ans || return 1
        if [ -z "$ans" ]; then
            [ "$def" = "y" ] && return 0
            return 1
        fi
        case "$ans" in
            1) return 0 ;;
            2) return 1 ;;
            *) warn "$(bi "Ответьте цифрой: 1 — да, 2 — нет." "Answer with a digit: 1 for yes, 2 for no.")" ;;
        esac
    done
    return 1
}

# ── язык: спрашиваем первым делом ───────────────────────────────────────
# Угадывать по локали нельзя: на сервере со штатной en_US.UTF-8 русскому
# подписчику доставался английский, а SSH нередко присылает ту же en_US.
# Язык спрашивается первым экраном, ДО проверок: иначе отказ по ОС или
# «Проверяю ключ…» уже прозвучали бы на чужом языке. Спрошенное
# запоминается; сменить — пунктом меню, задать без вопроса — GOINST_LANG.
LANG_ASKED=""

# lang_pick [умолчание] — экран выбора. Ставит LANG_CODE; rc 1 — отказ.
# Экран сам двуязычный: язык человека ещё неизвестен.
lang_pick() {
    local def="${1:-}" c tries=0 m1="" m2=""
    case "$def" in
        ru|en) ;;
        *) def=$(lang_neighbour) || def="ru" ;;
    esac
    if [ "$def" = "en" ]; then m2=" ${DIM}Enter${NC}"; else m1=" ${DIM}Enter${NC}"; fi
    while [ "$tries" -lt 3 ]; do
        tries=$((tries+1))
        echo "" >&2
        echo -e "  ${CYAN}${BOLD}goInstaller ${GOINST_VERSION}${NC}" >&2
        echo -e "  Выберите язык / Choose language" >&2
        echo -e "  ${CYAN}1)${NC} Русский${m1}" >&2
        echo -e "  ${CYAN}2)${NC} English${m2}" >&2
        read_line c || return 1
        if [ -z "$c" ]; then
            if [ "$def" = "en" ]; then c=2; else c=1; fi
        fi
        case "$c" in
            1) LANG_CODE="ru"; LANG_ASKED="yes"; return 0 ;;
            2) LANG_CODE="en"; LANG_ASKED="yes"; return 0 ;;
            *) echo -e "  ${YELLOW}!${NC}  Ответьте цифрой 1 или 2 / Answer with 1 or 2" >&2 ;;
        esac
    done
    return 1
}

# Спросить язык, если он ещё не выбран и есть с кем говорить.
lang_startup() {
    [ -z "${GOINST_LANG:-}" ] || return 0
    _lang_marker "$(lang_file)" >/dev/null && return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    lang_pick
}

# Запомнить выбор. Зовётся ПОСЛЕ проверки root: язык нужно было спросить
# ещё до неё, а писать в /opt без прав бессмысленно.
lang_persist() {
    local f d
    [ "$LANG_ASKED" = "yes" ] || return 0
    f=$(lang_file); d=$(dirname "$f")
    mkdir -p "$d" 2>/dev/null || return 0
    printf '%s\n' "$LANG_CODE" > "$f" 2>/dev/null || return 0
    chmod 644 "$f" 2>/dev/null || true
    LANG_ASKED=""
    return 0
}

# ── продукты: имена и описания ──────────────────────────────────────────
prod_name() {
    case "$1" in
        govless)    printf 'goVLESS pro' ;;
        gotelegram) printf 'goTelegram pro' ;;
        godns)      printf 'goDNS pro' ;;
        gokaskad)   printf 'goKaskad pro' ;;
        gowarp)     printf 'goWARP pro' ;;
        goamnezia)  printf 'goAmnezia pro' ;;
        gocdn)      printf 'gocdn' ;;
        xui)        printf '3X-UI' ;;
        mtproxy)    printf 'MTProxy (mtg)' ;;
        *)          printf '%s' "$1" ;;
    esac
}

prod_desc() {
    case "$1" in
        govless)    bi "VLESS Reality/TLS на 3X-UI, бот, mini-app" "VLESS Reality/TLS on 3X-UI, bot, mini-app" ;;
        gotelegram) bi "MTProxy (telemt), сайт-маска, бот, панель" "MTProxy (telemt), mask site, bot, panel" ;;
        godns)      bi "DoH/DoT-резолвер на сертификате соседа" "DoH/DoT resolver on a neighbour's certificate" ;;
        gokaskad)   bi "каскад портов (iptables), бот, прокси для API Telegram" "port cascade (iptables), bot, Telegram API egress" ;;
        gowarp)     bi "Cloudflare WARP как SOCKS5 для 3X-UI" "Cloudflare WARP as SOCKS5 for 3X-UI" ;;
        goamnezia)  bi "AmneziaWG в Docker, сайт-маска, бот, панель" "AmneziaWG in Docker, mask site, bot, panel" ;;
    esac
}

prod_cmd() {
    case "$1" in
        govless) printf 'govless' ;; gotelegram) printf 'gotelegram' ;;
        godns) printf 'godns' ;; gokaskad) printf 'gokaskad' ;; gowarp) printf 'gowarp' ;;
        goamnezia) printf 'goamnezia' ;;
    esac
}

# Признак «установлен» — тот же, каким пользуется сам продукт.
# GOINST_FAKE_INSTALLED="godns govless" — подмена для тестов: они гоняют
# проверку портов на фикстурах, а не на живой машине.
prod_installed() {
    if [ -n "${GOINST_FAKE_INSTALLED+x}" ]; then
        case " ${GOINST_FAKE_INSTALLED} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
    fi
    case "$1" in
        govless)    [ -f /usr/local/x-ui/x-ui ] && [ -f /opt/govless/config.json ] ;;
        gotelegram) [ -x /usr/local/bin/telemt ] && [ -f /opt/gotelegram/config.json ] ;;
        godns)      _godns_state_present ;;
        gokaskad)   [ -x /usr/local/bin/gokaskad ] || [ -f /etc/kaskad/config ] ;;
        gowarp)     [ -x /usr/local/bin/gowarp ] || [ -f /etc/warp-manager/config ] ;;
        goamnezia)  _goamnezia_installed ;;
        *) return 1 ;;
    esac
}

# ── бесплатный Lite из инструкции на месте goVLESS pro ──────────────────
# goVLESS Lite из бесплатной инструкции (anten-ka/govless-lite-version)
# ставится туда же, куда goVLESS pro: код — клоном в /opt/govless-installer,
# настройки — в /opt/govless/config.json, команда — govless. По признакам
# установки он неотличим от pro, и goInstaller показывал его как «goVLESS pro
# установлен 1.3.6», а пункт «Открыть меню продукта» запускал меню Lite.
# Отличает их только то, откуда взят код: клон Lite смотрит в репозиторий Lite.
GOVLESS_LITE_REPO="anten-ka/govless-lite-version"

# git_origin <каталог> — адрес origin клона. Читается прямо из .git/config:
# git на машине может не стоять, а в тестах дерево подложено. Без awk:
# mawk 1.3.3 из Debian 10 не знает классов вроде [[:space:]].
git_origin() {
    local cfg="$1/.git/config" line sect="" url=""
    [ -r "$cfg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            '['*) sect="$line"; continue ;;
        esac
        [ "$sect" = '[remote "origin"]' ] || continue
        case "$line" in
            url=*|url[[:space:]]*=*)
                url="${line#*=}"; url="${url#"${url%%[![:space:]]*}"}"
                break ;;
        esac
    done < "$cfg"
    [ -n "$url" ] || return 1
    printf '%s' "$url"
}

# repo_slug <адрес> — «owner/repo» строчными: https, ssh, адрес с ключом и
# адрес без .git — один репозиторий, а GitHub не различает регистр в именах.
repo_slug() {
    local u="${1%/}"
    u="${u%.git}"; u="${u#*://}"; u="${u#*@}"; u="${u/github.com:/github.com/}"
    u="${u#github.com/}"
    printf '%s' "${u,,}"
}

# prod_free_lite <id> — код продукта на сервере взят из бесплатного Lite.
# Установленным продукт при этом остаётся: Lite держит те же порты и юниты,
# и соседям он мешает ровно так же, как goVLESS pro в режиме Lite.
prod_free_lite() {
    local url
    [ "$1" = govless ] || return 1
    url=$(git_origin "${GOINST_FS_ROOT:-}/opt/govless-installer") || return 1
    # По имени репозитория, а не по владельцу: форк и зеркало Lite имя берегут.
    case "/$(repo_slug "$url")" in
        */"${GOVLESS_LITE_REPO##*/}") return 0 ;;
    esac
    return 1
}

# Бесплатный Kaskad (anten-ka/kaskad) копирует себя в ту же
# /usr/local/bin/gokaskad, что и goKaskad pro: goInstaller принимал его за pro
# и пунктом «Открыть меню продукта» запускал бесплатное меню. Отличает их
# строка версии: KASKAD_VERSION= есть в каждом коммите pro и ни в одной
# бесплатной версии.
_gokaskad_free() {
    local f="${GOINST_FS_ROOT:-}/usr/local/bin/gokaskad"
    [ -f "$f" ] || return 1
    ! ver_extract "$f" KASKAD_VERSION >/dev/null 2>&1
}

# Бесплатный MTProxy (anten-ka/gotelegram_mtproxy) при каждом запуске копирует
# себя в /usr/local/bin/gotelegram. У goTelegram pro до 2.10.50 это был симлинк
# на /opt/gotelegram/install.sh, и копия затирала сам установщик pro; с
# обёрткой затирается только команда. В обоих случаях goInstaller видел
# «goTelegram pro установлен» и пунктом меню запускал бесплатный скрипт. Метка
# бесплатного — строка `docker inspect mtproto-proxy`: она есть во всех его
# версиях и ни в одном коммите pro (там имя контейнера в переменной).
_gotelegram_free_code() {
    local r="${GOINST_FS_ROOT:-}" f
    for f in "$r/usr/local/bin/gotelegram" "$r/opt/gotelegram/install.sh"; do
        [ -f "$f" ] || continue
        grep -qF 'docker inspect mtproto-proxy' "$f" 2>/dev/null && return 0
    done
    return 1
}

# prod_free_edition <id> — вместо продукта стоит его бесплатная версия из
# публичной инструкции. Печатает её имя для экрана: «бесплатный <имя>».
# Номер версии рядом осмыслен только у Lite: у Kaskad его нет, а у goTelegram
# это номер pro, чей код бесплатный скрипт подменил (prod_free_shows_version).
prod_free_shows_version() { [ "$1" = govless ]; }

prod_free_edition() {
    case "$1" in
        govless)  prod_free_lite govless || return 1; printf 'Lite' ;;
        gokaskad) _gokaskad_free || return 1; printf 'Kaskad' ;;
        gotelegram) _gotelegram_free_code || return 1; printf 'MTProxy' ;;
        *) return 1 ;;
    esac
}

# Где продукт держит свои настройки. Оттуда же читается режим.
prod_config_file() {
    local r="${GOINST_FS_ROOT:-}"
    case "$1" in
        govless)    printf '%s' "${GOINST_GOVLESS_CONFIG:-$r/opt/govless/config.json}" ;;
        gotelegram) printf '%s' "${GOINST_GOTELEGRAM_CONFIG:-$r/opt/gotelegram/config.json}" ;;
        goamnezia)  printf '%s' "${GOINST_GOAMNEZIA_CONFIG:-$r/opt/goamnezia/config.json}" ;;
        godns)      printf '%s' "${GOINST_GODNS_CONFIG:-$r/opt/godns/config.json}" ;;
        *) return 1 ;;
    esac
}

# Режим установленного продукта. Все три продукта с режимами пишут его
# одним и тем же ключом `mode` в свой config.json — спрашивать человека о
# том, что уже записано на диске, незачем.
prod_installed_mode() {
    local id="$1" f m
    f=$(prod_config_file "$id") || return 1
    [ -r "$f" ] || return 1
    m=$(sed -n -E 's/.*"mode"[[:space:]]*:[[:space:]]*"([a-z_]+)".*/\1/p' "$f" 2>/dev/null | head -1) || m=""
    [ -n "$m" ] || return 1
    # Значение должно быть из списка режимов ЭТОГО продукта: чужое или
    # незнакомое слово режимом не считается, иначе проверка портов пойдёт
    # по пустому набору и скажет «всё свободно».
    case " $(prod_modes "$id") " in
        *" $m "*) printf '%s' "$m"; return 0 ;;
    esac
    return 1
}

# goAmnezia сам считает себя установленным по ключу `.installed` в своём
# config.json, а не по наличию файла: файл появляется раньше, чем мастер
# доходит до конца.
_goamnezia_installed() {
    local f
    f=$(prod_config_file goamnezia)
    [ -f "$f" ] || return 1
    grep -qE '"installed"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null
}

# У goDNS config.json появляется уже при выборе языка; «стоит» — только
# когда есть домен, отпечаток применённой конфигурации или версия.
_godns_state_present() {
    local f=/opt/godns/config.json
    [ -f "$f" ] || return 1
    command -v python3 >/dev/null 2>&1 || { grep -qE '"(domain|applied_fingerprint|godns_version)"[[:space:]]*:[[:space:]]*"[^"]+"' "$f"; return; }
    python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if any(d.get(k) for k in ("domain", "applied_fingerprint", "godns_version")) else 1)
PY
}

# Версия — как получится: у каждого продукта она лежит по-своему.
# ── версии: одна таблица на локальную и на удалённую ────────────────────
# Номер версии у каждого продукта лежит в своём файле и в своей переменной.
# Таблица ОДНА: тот же путь читается и в дереве на сервере, и в репозитории
# на GitHub. Разойдись они — «установлено 2.8» и «в ветке 2.8» считались бы
# по разным правилам, и совет «обновиться нечем» врал бы молча.
#
# prod_ver_spec <id> → "путь_в_репозитории|переменная"
prod_ver_spec() {
    case "$1" in
        govless)    printf 'lib/common.sh|GOVLESS_VERSION' ;;
        gotelegram) printf 'lib/common.sh|GOTELEGRAM_VERSION' ;;
        godns)      printf 'lib/common.sh|GODNS_VERSION' ;;
        gokaskad)   printf 'install.sh|KASKAD_VERSION' ;;
        gowarp)     printf 'warp.sh|WARP_VERSION' ;;
        goamnezia)  printf 'lib/common.sh|GOAMNEZIA_VERSION' ;;
    esac
}

# Каталоги, где на сервере лежит КОД установленного продукта. Их несколько:
# goVLESS кладёт дерево по-разному в зависимости от того, каким из двух
# своих загрузчиков его ставили, а Kaskad и goWARP — сами себе программа
# в /usr/local/bin.
# GOINST_FS_ROOT — префикс для тестов: версию установленного продукта иначе
# нечем проверить, кроме как на машине, где он стоит.
prod_local_dirs() {
    local r="${GOINST_FS_ROOT:-}"
    case "$1" in
        govless)    printf '%s\n' "$r/opt/govless-installer" "$r$HOME/goVLESS" "$r/root/goVLESS" ;;
        gotelegram) printf '%s\n' "$r/opt/gotelegram" ;;
        godns)      printf '%s\n' "$r/opt/godns-installer" ;;
        gokaskad)   printf '%s\n' "$r/usr/local/bin" ;;
        gowarp)     printf '%s\n' "$r/usr/local/bin" ;;
        goamnezia)  printf '%s\n' "$r/opt/goamnezia" ;;
    esac
}

# Имя файла на диске: у Kaskad и goWARP оно другое, чем в репозитории.
prod_local_file() {
    case "$1" in
        gokaskad) printf 'gokaskad' ;;
        gowarp)   printf 'gowarp' ;;
        *)        printf '%s' "${2}" ;;
    esac
}

# Достать номер версии из файла. Присваивание ищем в начале строки:
# упоминание переменной в комментарии или в сообщении версией не является.
ver_extract() {
    local file="$1" var="$2" v
    [ -r "$file" ] || return 1
    v=$(sed -n -E "s/^[[:space:]]*${var}=\"?([0-9][^\"[:space:]]*)\"?.*/\1/p" "$file" 2>/dev/null | head -1) || v=""
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# То же, но без знания имени переменной: годится любая
# «ЧТО_ТО_VERSION="1.2.3"» в начале строки. Нужна, когда продукт переехал и
# таблица-подсказка устарела: список продуктов не должен требовать правки
# установщика ради переименованной переменной.
ver_extract_any() {
    local file="$1" v
    [ -r "$file" ] || return 1
    v=$(sed -n -E 's/^[[:space:]]*[A-Z][A-Z0-9_]*VERSION=\"?([0-9][^\"[:space:]]*)\"?.*/\1/p' "$file" 2>/dev/null | head -1) || v=""
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Файлы, в которых версия может лежать. Первый — подсказка из таблицы,
# дальше общие места. Спрашиваем по очереди и останавливаемся на первом
# ответе: лишние запросы к GitHub стоят времени на глазах у человека.
prod_ver_paths() {
    local id="$1" spec hint
    spec=$(prod_ver_spec "$id") || spec=""
    hint="${spec%%|*}"
    [ -n "$hint" ] && printf '%s\n' "$hint"
    local c
    for c in lib/common.sh install.sh bootstrap.sh "${id}.sh" warp.sh; do
        [ "$c" = "$hint" ] || printf '%s\n' "$c"
    done
}

prod_version() {
    local id="$1" spec path var d f v
    spec=$(prod_ver_spec "$id") || return 0
    path="${spec%%|*}"; var="${spec#*|}"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        f="$d/$(prod_local_file "$id" "$path")"
        if v=$(ver_extract "$f" "$var"); then printf '%s' "$v"; return 0; fi
    done < <(prod_local_dirs "$id")
    # goDNS дополнительно штампует версию в состоянии — годится, когда
    # каталог программы снесли, а состояние осталось.
    if [ "$id" = "godns" ]; then
        v=$(sed -n -E 's/.*"godns_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${GOINST_GODNS_CONFIG:-/opt/godns/config.json}" 2>/dev/null | head -1) || v=""
        [ -n "$v" ] && printf '%s' "$v"
    fi
    return 0
}

# Ветки спрашиваем у самого GitHub. Зашитый список устаревает молча: пока
# он лежал в коде, у goDNS появилась `main`, у goKaskad — `dev` (13.10, там
# goKaskad pro 3), а у goWARP ветки `dev` нет — и установщик либо не показывал существующее, либо
# стучался в несуществующее.
#
# Порядок осмысленный, а не алфавитный: сначала стабильная, потом
# отладочная, потом остальные. Человек читает первую строку как
# «обычный выбор».
# Оставляем только два уровня: стабильный и отладочный. Остальное в
# репозиториях — рабочие ветки авторов (`rc1`, `alfa-v2`, `v2.4-menu`,
# `backup/pre-v2.5`, `claude/*`), и предлагать их оператору незачем: он
# выбирает не место разработки, а зрелость кода. Динамика здесь в том,
# СУЩЕСТВУЕТ ли ветка: у goDNS `main` появилась, у goWARP `dev` нет.
# Кому нужна своя — задаёт GOINST_REFS_<id>.
refs_sort() {
    local b stable="" dev="" out
    while read -r b; do
        [ -n "$b" ] || continue
        case "$b" in
            main|master) stable="$b" ;;
            dev|develop) dev="$b" ;;
        esac
    done
    out="${stable:+$stable }${dev:+$dev}"
    printf '%s' "${out% }"
}

# Список веток кладём в тот же кеш, что и версии: ключ «<id>.@refs».
refs_fetch_one() {
    local id="$1" cfg="$2" repo names
    repo=$(prod_repo "$id")
    if [ -n "${GOINST_BRANCHES_FIXTURE:-}" ]; then
        names=$(sed -n -E "s#^${repo}=(.*)\$#\1#p" "$GOINST_BRANCHES_FIXTURE" 2>/dev/null | head -1 | tr ' ' '\n')
    else
        local tmp rc=0
        tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-refs.XXXXXX") || return 0
        gh_get "https://api.github.com/repos/${repo}/branches?per_page=100" "$cfg" "$tmp" || rc=$?
        if [ "$rc" -eq 2 ]; then
            # Лимит: прежний список остаётся, штамп свежий — иначе его
            # спрашивали бы на каждом такте.
            rm -f "$tmp"; ver_cache_touch "$id" "@refs"; return 0
        fi
        names=$(sed -n -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmp" 2>/dev/null) || names=""
        rm -f "$tmp"
    fi
    names=$(printf '%s\n' "$names" | refs_sort)
    ver_cache_write "$id" "@refs" "$names"
    return 0
}

# prod_refs <id> — что спрашивать и что показывать. Порядок источников:
# заданное человеком, узнанное у GitHub, и лишь потом запасной список для
# случая «сети нет, ключа нет».
prod_refs() {
    local v="GOINST_REFS_$1" cached
    if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return 0; fi
    if cached=$(ver_cache_get "$1" "@refs") && [ -n "$cached" ]; then
        printf '%s' "$cached"; return 0
    fi
    printf 'main dev'
}

# Сколько веток опрашиваем на версию. Репозиторий с десятком веток иначе
# превращается в десяток запросов на каждый продукт, а смысла в версии
# ветки `backup/pre-v2.5` нет никакого.
REFS_MAX="${GOINST_REFS_MAX:-3}"
prod_refs_probe() {
    local id="$1" n=0 r
    for r in $(prod_refs "$id"); do
        n=$((n+1)); [ "$n" -le "$REFS_MAX" ] || break
        printf '%s\n' "$r"
    done
}

# ── ОС ──────────────────────────────────────────────────────────────────
# /etc/os-release не source-им: файл управляем извне.
osr() {
    local v
    v=$(sed -n -E "s/^[[:space:]]*$1=(.*)\$/\1/p" "${GOINST_OS_RELEASE:-/etc/os-release}" 2>/dev/null) || v=""
    v="${v%%$'\n'*}"; v="${v%\"}"; v="${v#\"}"; printf '%s' "$v"
}
OS_ID=""; OS_VER=""; OS_PRETTY=""; OS_LIKE=""; OS_MAJ=0; OS_MIN=0; OS_ARCH=""
os_detect() {
    OS_ARCH="${GOINST_ARCH:-$(uname -m 2>/dev/null)}"
    OS_ID="$(osr ID)"; OS_VER="$(osr VERSION_ID)"; OS_PRETTY="$(osr PRETTY_NAME)"; OS_LIKE="$(osr ID_LIKE)"
    local maj="${OS_VER%%.*}" min="${OS_VER#*.}"; min="${min%%.*}"
    case "$maj" in ''|*[!0-9]*) maj=0 ;; esac
    case "$min" in ''|*[!0-9]*) min=0 ;; esac
    OS_MAJ=$((10#$maj)); OS_MIN=$((10#$min))
}

# Общие ворота: Ubuntu или Debian с apt. Всё остальное отсекается здесь,
# частные требования продуктов — в prod_os_check.
os_gate_common() {
    case "$OS_ID" in
        ubuntu|debian) ;;
        *)
            case " $OS_LIKE " in
                *" ubuntu "*|*" debian "*)
                    die "$(bi "Это производная (${OS_PRETTY:-ID=$OS_ID}), а не Ubuntu/Debian. Продукты серии go проверены только на оригинальных выпусках." "This is a derivative (${OS_PRETTY:-ID=$OS_ID}), not Ubuntu/Debian. The go products are tested only on original releases.")" ;;
                *) die "$(bi "Неподдерживаемая система: ${OS_PRETTY:-ID=$OS_ID}. Нужна Ubuntu или Debian." "Unsupported system: ${OS_PRETTY:-ID=$OS_ID}. Ubuntu or Debian is required.")" ;;
            esac ;;
    esac
    [ -n "${GOINST_TEST:-}" ] || command -v apt-get >/dev/null 2>&1 || die "$(bi "Нет apt-get — установщики продуктов на нём построены." "apt-get is missing — the product installers depend on it.")"
}

# prod_os_check <id> → печатает строки "must|…" / "soft|…"; ничего — всё хорошо.
# Требования сняты с установщиков самих продуктов, а не придуманы.
prod_os_check() {
    case "$1" in
        godns)
            if [ "$OS_ID" != "ubuntu" ]; then
                echo "must|$(bi "goDNS pro ставится только на Ubuntu 22.04 / 24.04 / 26.04 (найдена ${OS_PRETTY})." "goDNS pro installs only on Ubuntu 22.04 / 24.04 / 26.04 (found ${OS_PRETTY}).")"
            elif [ "$OS_MAJ" -lt 22 ]; then
                echo "must|$(bi "goDNS pro требует Ubuntu 22.04 или новее (найдена ${OS_PRETTY})." "goDNS pro requires Ubuntu 22.04 or newer (found ${OS_PRETTY}).")"
            fi ;;
        gotelegram)
            # Гейт ОС у goTelegram pro — только в первой установке
            # (menu_install → preflight_os_gate). Стоящий продукт обновляется
            # на любой ОС: строки нет.
            prod_installed gotelegram && return 0
            if [ "$OS_ID" = "ubuntu" ] && [ "$OS_MAJ" -lt 24 ]; then
                echo "must|$(bi "goTelegram pro при первой установке требует Ubuntu 24.04 или новее (найдена ${OS_PRETTY}); установщик продукта откажется сам." "goTelegram pro requires Ubuntu 24.04 or newer for a first install (found ${OS_PRETTY}); the product installer refuses on its own.")"
            elif [ "$OS_ID" = "debian" ]; then
                echo "soft|$(bi "Debian у goTelegram pro не в списке проверенных — установщик продукта предупредит." "Debian is not on goTelegram pro's tested list — the product installer will warn.")"
            fi ;;
        govless)
            # require_fresh_os (goVLESS lib/common.sh) зовётся только при новой
            # установке: нет x-ui или нет /opt/govless/config.json. Бесплатный
            # Lite кладёт оба, поэтому pro поверх него для goVLESS pro — не
            # новая установка; prod_installed смотрит на те же два файла.
            prod_installed govless && return 0
            if { [ "$OS_ID" = "ubuntu" ] && { [ "$OS_MAJ" -lt 24 ] || { [ "$OS_MAJ" -eq 24 ] && [ "$OS_MIN" -lt 4 ]; }; }; } \
               || { [ "$OS_ID" = "debian" ] && [ "$OS_MAJ" -lt 12 ]; }; then
                echo "must|$(bi "goVLESS pro при новой установке требует Ubuntu 24.04+ или Debian 12+ (найдена ${OS_PRETTY})." "goVLESS pro requires Ubuntu 24.04+ or Debian 12+ for a new install (found ${OS_PRETTY}).")"
            fi ;;
        # goWARP pro: у Cloudflare есть пакет и для новых Ubuntu (resolute
        # проверен), предупреждать не о чем.
        gowarp) ;;
        goamnezia)
            # Образы Amnezia собраны только под amd64, и продукт отказывается
            # ставиться на всём остальном. Сказать это надо до установки, а не
            # после скачивания.
            case "$OS_ARCH" in
                x86_64|amd64) ;;
                *) echo "must|$(bi "goAmnezia pro ставится только на amd64 (найдена ${OS_ARCH:-неизвестно}): образы Amnezia собраны под неё одну." "goAmnezia pro installs only on amd64 (found ${OS_ARCH:-unknown}): Amnezia's images are built for it alone.")" ;;
            esac
            # Проверки выпуска у продукта нет, но на 20.04 бот (python 3.8) и
            # сайт (certbot 0.40) не встают; AmneziaWG встаёт.
            if [ "$OS_ID" = "ubuntu" ] && [ "$OS_MAJ" -lt 22 ]; then
                echo "soft|$(bi "на ${OS_PRETTY} бот (python 3.8) и сайт (certbot 0.40) goAmnezia pro не встанут, AmneziaWG — встанет." "on ${OS_PRETTY} the goAmnezia pro bot (python 3.8) and site (certbot 0.40) will not install, AmneziaWG will.")"
            fi
            ;;
        gokaskad) ;;
    esac
    return 0
}

# ── порты: кто что держит ───────────────────────────────────────────────
# Снимок слушателей: строки "proto|addr|port|proc|pid". Один вызов ss на
# весь экран, дальше — чистая работа со строками.
LISTENERS=""
_SCAN_STAMP=""
# Кеш нужен ровно на время сборки экрана меню: там preflight зовётся по разу
# на каждый продукт, и без кеша это семь вызовов ss на одну перерисовку.
# Включает и выключает его только menu_items_main — во всех остальных местах
# снимок обязан быть свежим.
scan_cache_begin() { _SCAN_STAMP=""; _DOCKER_STAMP=""; GOINST_SCAN_CACHE=1; }
scan_cache_end()   { unset GOINST_SCAN_CACHE; _SCAN_STAMP=""; _DOCKER_STAMP=""; }
# with_scan_cache <команда…> — один скан ss и docker на всё время команды.
# Внутри уже открытого кеша — просто команда: конец вложенного кеша закрыл
# бы внешний, и остаток пересборки снова звал бы docker ps на каждый порт.
with_scan_cache() {
    if [ -n "${GOINST_SCAN_CACHE:-}" ]; then "$@"; return $?; fi
    local rc=0
    scan_cache_begin; "$@" || rc=$?; scan_cache_end
    return "$rc"
}
scan_listeners() {
    local raw
    if [ -n "${GOINST_SCAN_CACHE:-}" ] && [ -n "$_SCAN_STAMP" ]; then return 0; fi
    _SCAN_STAMP="done"
    if [ -n "${GOINST_SS_FIXTURE:-}" ]; then
        raw=$(cat "$GOINST_SS_FIXTURE" 2>/dev/null) || raw=""
    else
        raw=$(ss -H -lntup 2>/dev/null) || raw=""
    fi
    LISTENERS=$(printf '%s\n' "$raw" | awk '
        NF >= 5 {
            proto = $1; local = $5; users = "";
            for (i = 6; i <= NF; i++) if ($i ~ /^users:/) users = $i;
            n = split(local, a, ":"); port = a[n];
            addr = substr(local, 1, length(local) - length(port) - 1);
            gsub(/^\[|\]$/, "", addr); sub(/%.*$/, "", addr);
            proc = ""; pid = "";
            if (match(users, /\("[^"]+",pid=[0-9]+/)) {
                s = substr(users, RSTART + 2, RLENGTH - 2);
                split(s, b, "\",pid="); proc = b[1]; pid = b[2];
            }
            if (port ~ /^[0-9]+$/) print proto "|" addr "|" port "|" proc "|" pid;
        }')
}

# Юнит systemd по PID: /proc/<pid>/cgroup → «…/dnsdist.service».
pid_unit() {
    local pid="$1" line
    [ -n "$pid" ] || return 0
    if [ -n "${GOINST_UNIT_FIXTURE:-}" ]; then
        sed -n -E "s/^${pid}=//p" "$GOINST_UNIT_FIXTURE" 2>/dev/null | head -1; return 0
    fi
    line=$(sed -n -E 's#^0::.*/([^/]+\.service)$#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -1) || line=""
    printf '%s' "$line"
}

# Кому принадлежит слушатель: id продукта, «nginx», «system» или имя процесса.
holder_product() {
    local proc="$1" pid="$2" unit
    unit=$(pid_unit "$pid")
    case "$unit" in
        goamnezia*) printf 'goamnezia'; return ;;
        x-ui.service) _xui_owner; return ;;
        govless*|govlessctl*|cloudflared*|webapp-frontend*|tunnel-health*) printf 'govless'; return ;;
        telemt.service|gotelegram*) printf 'gotelegram'; return ;;
        dnsdist.service|godns*) printf 'godns'; return ;;
        kaskad*) printf 'gokaskad'; return ;;
        warp-svc.service|warp-bot.service|gowarp*) printf 'gowarp'; return ;;
        gocdn*) printf 'gocdn'; return ;;
        nginx.service) _nginx_owner; return ;;
        systemd-resolved.service|sshd.service|ssh.service|chrony*|cups*|rpcbind*|exim*|postfix*) printf 'system'; return ;;
    esac
    case "$proc" in
        xray|xray-linux*|x-ui) _xui_owner ;;
        telemt) printf 'gotelegram' ;;
        dnsdist) printf 'godns' ;;
        warp-svc) printf 'gowarp' ;;
        nginx) _nginx_owner ;;
        systemd-resolve|systemd-resolved|sshd|chronyd|ntpd) printf 'system' ;;
        *) printf '%s' "${proc:-?}" ;;
    esac
}

# x-ui — штатный юнит ЛЮБОЙ панели 3X-UI, а не только goVLESS pro: панель
# ставили и по старым инструкциям, и руками. Порты такой панели проверка
# звала «остатками прежней установки goVLESS pro» и запрещала ставить, хотя
# установщик goVLESS pro на ней не спотыкается, а берёт её себе. Панель —
# goVLESS pro, только когда он сам стоит (бесплатный Lite тоже считается).
_xui_owner() { if prod_installed govless; then printf 'govless'; else printf 'xui'; fi; }

# Панель 3X-UI есть, а goVLESS pro нет.
govless_foreign_panel() {
    [ -f "${GOINST_FS_ROOT:-}/usr/local/x-ui/x-ui" ] && ! prod_installed govless
}

# nginx общий: смотрим, чей сайт включён.
_nginx_owner() {
    local root="${GOINST_NGINX_ROOT:-/etc/nginx}"
    if [ -e "$root/sites-enabled/gotelegram" ] || [ -e "$root/stream-conf.d/gotelegram-shared443.conf" ]; then printf 'gotelegram'
    elif [ -e "$root/sites-enabled/govless" ]; then printf 'govless'
    elif [ -e "$root/sites-enabled/goamnezia" ]; then printf 'goamnezia'
    else printf 'nginx'; fi
}

# ── порты, занятые контейнерами ─────────────────────────────────────────
# Опубликованный порт контейнера виден в `ss` как docker-proxy, а при
# `userland-proxy: false` не виден ВОВСЕ: трафик уводит DNAT, слушателя на
# хосте нет. Без этого опроса проверка сказала бы «свободен» про порт,
# который занят, — и это ровно тот случай, ради которого затевалась
# проверка. goAmnezia держит AmneziaWG именно в контейнерах.
DOCKER_PORTS=""
_DOCKER_STAMP=""; DOCKER_ERR=""
# docker ps, который не молчит о провале. Клиент docker новее демона —
# частый случай после обновления пакета без перезапуска демона: «client
# version 1.52 is too new. Maximum supported API version is 1.47». Тогда
# повторяем с той версией API, которую демон назвал сам (так же делает
# goAmnezia pro). Не вышло — причина в DOCKER_ERR: её показывает проверка
# портов, иначе «docker-proxy» на порту остаётся загадкой.
_docker_ps() {
    local errf err v rc=0
    DOCKER_ERR=""
    errf=$(mktemp "${TMPDIR:-/tmp}/goinst-dk.XXXXXX") || errf=/dev/null
    # Зависший демон не должен вешать меню: пять секунд, дальше — «не ответил».
    local -a to=() dt="${GOINST_DOCKER_TIMEOUT:-5}"
    case "$dt" in ''|*[!0-9]*) dt=5 ;; esac
    command -v timeout >/dev/null 2>&1 && to=(timeout "$dt")
    DOCKER_PS=$(${to[@]+"${to[@]}"} docker ps --format '{{.Names}} {{.Ports}}' 2>"$errf") || rc=$?
    if [ "$rc" -ne 0 ]; then
        err=$(cat "$errf" 2>/dev/null) || err=""
        v="${err#*aximum supported API version is }"; v="${v%%[!0-9.]*}"
        if [ "$v" != "$err" ] && [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
            rc=0; DOCKER_PS=$(DOCKER_API_VERSION="$v" ${to[@]+"${to[@]}"} docker ps --format '{{.Names}} {{.Ports}}' 2>"$errf") || rc=$?
            [ "$rc" -eq 0 ] || err=$(cat "$errf" 2>/dev/null) || err=""
        fi
        if [ "$rc" -ne 0 ]; then
            DOCKER_PS=""; err="${err%%$'\n'*}"; err="${err//[|]//}"; err="${err//[^[:print:]]/}"
            [ "$rc" -eq 124 ] && err="docker ps не ответил за ${dt} с"
            DOCKER_ERR="${err:0:120}"; [ -n "$DOCKER_ERR" ] || DOCKER_ERR="docker ps: код $rc"
        fi
    fi
    [ "$errf" = /dev/null ] || rm -f "$errf"
    return 0
}

scan_docker() {
    local raw name rest tok p port proto
    if [ -n "${GOINST_SCAN_CACHE:-}" ] && [ -n "$_DOCKER_STAMP" ]; then return 0; fi
    _DOCKER_STAMP="done"; DOCKER_PORTS=""; DOCKER_ERR=""
    if [ -n "${GOINST_DOCKER_FIXTURE:-}" ]; then
        raw=$(cat "$GOINST_DOCKER_FIXTURE" 2>/dev/null) || raw=""
    elif command -v docker >/dev/null 2>&1; then
        _docker_ps; raw="$DOCKER_PS"
    else
        return 0
    fi
    while read -r name rest; do
        [ -n "$name" ] || continue
        for tok in $(printf '%s' "$rest" | tr ',' ' '); do
            case "$tok" in
                *'->'*)
                    # Порт — со стороны сервера, до «->»: его и держит
                    # docker-proxy. После «->» — порт внутри контейнера, при
                    # публикации 8443->443 это другой номер.
                    p="${tok%%->*}"; port="${p##*:}"; proto="${tok##*/}"
                    case "$proto" in tcp|udp) ;; *) continue ;; esac
                    # docker сам сворачивает соседние порты: 1000-1002->1000-1002/udp.
                    if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
                        [ $(( 10#$b - 10#$a )) -ge 0 ] && [ $(( 10#$b - 10#$a )) -le 1024 ] || continue
                        for ((a = 10#$a; a <= 10#$b; a++)); do DOCKER_PORTS+="${proto}|${a}|${name}"$'\n'; done
                        continue
                    fi
                    case "$port" in ''|*[!0-9]*) continue ;; esac
                    DOCKER_PORTS+="${proto}|${port}|${name}"$'\n' ;;
            esac
        done
    done <<<"$raw"
    return 0
}

# Контейнер → продукт. Имена AmneziaWG — общий неймспейс приложения Amnezia,
# goAmnezia и goWARP; для нас важно, что порт занят, и кем именно заведён.
# Продукт, который держит свои порты в контейнерах Docker.
prod_uses_docker() { case "$1" in goamnezia) return 0 ;; *) return 1 ;; esac; }

container_product() {
    case "$1" in
        amnezia-awg[0-9]*|amnezia-awg) printf 'goamnezia' ;;
        # Прежний MTProxy на mtg: бесплатная версия из инструкции
        # (anten-ka/gotelegram_mtproxy) и goTelegram pro первой версии держат
        # прокси в контейнере с этим именем.
        mtproto-proxy) printf 'mtproxy' ;;
        *) printf '%s' "$1" ;;
    esac
}

# port_holders <proto> <port> → строки "proc|pid|owner|addr" (может быть несколько)
port_holders() {
    local proto="$1" port="$2" l p a po pr pi found=0 name
    if [ -n "$LISTENERS" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            IFS='|' read -r p a po pr pi <<<"$l"
            [ "$p" = "$proto" ] && [ "$po" = "$port" ] || continue
            # docker-proxy сам по себе ничего не говорит: за ним стоит
            # контейнер, и назвать надо его.
            if [ "$pr" = "docker-proxy" ]; then
                name=$(_docker_holder "$proto" "$port") || name=""
                if [ -n "$name" ]; then
                    printf '%s|%s|%s|%s\n' "docker:${name}" "$pi" "$(container_product "$name")" "$a"
                    found=1; continue
                fi
            fi
            printf '%s|%s|%s|%s\n' "$pr" "$pi" "$(holder_product "$pr" "$pi")" "$a"
            found=1
        done <<<"$LISTENERS"
    fi
    [ "$found" -eq 1 ] && return 0
    # Слушателя нет — порт всё ещё может держать контейнер через DNAT.
    name=$(_docker_holder "$proto" "$port") || return 0
    [ -n "$name" ] || return 0
    printf 'docker:%s||%s|0.0.0.0\n' "$name" "$(container_product "$name")"
}

_docker_holder() {
    local proto="$1" port="$2" l p po name
    scan_docker
    [ -n "$DOCKER_PORTS" ] || return 1
    while IFS='|' read -r p po name; do
        [ "$p" = "$proto" ] && [ "$po" = "$port" ] || continue
        printf '%s' "$name"; return 0
    done <<<"$DOCKER_PORTS"
    return 1
}

# ── порты: что нужно каждому продукту ───────────────────────────────────
# Строка: proto|port|level|назначение. level: must — без этого порта
# продукт не встанет; soft — у продукта есть запасной вариант, но
# предупредить надо; info — просто сказать, что порт станет занят.
# Каждая строка снята с кода продукта (см. README, таблица портов).
prod_ports() {
    local id="$1" mode="${2:-pro}"
    case "$id" in
        govless)
            echo "tcp|443|must|$(bi "VLESS inbound xray — жёстко 443 в обоих режимах" "VLESS inbound (xray) — hardcoded 443 in both modes")"
            if [ "$mode" = "pro" ]; then
                echo "tcp|80|must|$(bi "nginx: сайт-маска и ACME-проверка certbot" "nginx: mask site and certbot ACME challenge")"
            else
                echo "tcp|80|soft|$(bi "nginx-заглушка и acme.sh для сертификата панели" "nginx stub and acme.sh for the panel certificate")"
            fi
            echo "tcp|8443|soft|$(bi "loopback: mini-app бота (режим Lite)" "loopback: bot mini-app (Lite mode)")"
            echo "tcp|10808|soft|$(bi "loopback: SOCKS5 прокси для API Telegram" "loopback: SOCKS5 Telegram API egress")"
            echo "tcp|10851|soft|$(bi "loopback: API xray для балансировщика прокси" "loopback: xray API for the egress balancer")"
            echo "tcp|18181|soft|$(bi "loopback: метрики cloudflared (режим Lite)" "loopback: cloudflared metrics (Lite mode)")"
            ;;
        gotelegram)
            if [ "$mode" = "pro" ]; then
                echo "tcp|443|must|$(bi "telemt MTProxy — жёстко 443 в режиме pro" "telemt MTProxy — hardcoded 443 in pro mode")"
                echo "tcp|80|must|$(bi "nginx: ACME-проверка certbot и редирект на https" "nginx: certbot ACME challenge and https redirect")"
                echo "tcp|8443|must|$(bi "loopback: nginx с сайтом-маской за telemt" "loopback: nginx mask site behind telemt")"
            else
                echo "tcp|443|soft|$(bi "telemt MTProxy — порт по умолчанию, можно выбрать другой" "telemt MTProxy — default port, another can be chosen")"
            fi
            echo "tcp|9090|must|$(bi "loopback: метрики telemt (Prometheus)" "loopback: telemt metrics (Prometheus)")"
            echo "tcp|9091|must|$(bi "loopback: локальный API telemt" "loopback: telemt local API")"
            echo "tcp|1984|soft|$(bi "loopback: веб-панель (если ставить бота)" "loopback: admin web panel (if the bot is installed)")"
            echo "tcp|18080|soft|$(bi "loopback: WEB-транспорт telemt (если включён)" "loopback: telemt WEB transport (if enabled)")"
            echo "tcp|8444|soft|$(bi "loopback: decoy-хост nginx для WEB-транспорта" "loopback: nginx decoy vhost for WEB transport")"
            ;;
        godns)
            echo "tcp|443|info|$(bi "DoH: возьмёт 443 только если свободен и соседей нет" "DoH: takes 443 only if free and no neighbours")"
            echo "tcp|4443|soft|$(bi "DoH: первый кандидат при занятом 443 (дальше 8444 9444 5443 7444)" "DoH: first candidate when 443 is busy (then 8444 9444 5443 7444)")"
            echo "tcp|853|soft|$(bi "DoT (запасные 8853 9853 1853)" "DoT (fallbacks 8853 9853 1853)")"
            echo "tcp|5199|must|$(bi "loopback: консоль dnsdist" "loopback: dnsdist console")"
            echo "tcp|53|info|$(bi "loopback: обычный DNS 127.0.0.1:53, при занятости уедет на 127.0.0.2" "loopback: plain DNS 127.0.0.1:53, moves to 127.0.0.2 if busy")"
            echo "tcp|9445|soft|$(bi "веб-панель (кандидаты 9446 9447 8446 8447 9448 9449)" "web panel (candidates 9446 9447 8446 8447 9448 9449)")"
            echo "tcp|8642|soft|$(bi "loopback: внутренний порт веб-панели (8643…8646)" "loopback: web panel internal port (8643…8646)")"
            echo "tcp|80|info|$(bi "нужен ТОЛЬКО если выпускать свой сертификат, а не брать у соседа" "needed ONLY when issuing an own certificate instead of reusing a neighbour's")"
            ;;
        gokaskad)
            echo "tcp|10808|soft|$(bi "loopback: SOCKS5 прокси для API Telegram (если включить)" "loopback: SOCKS5 Telegram API egress (if enabled)")"
            echo "tcp|10851|soft|$(bi "loopback: API xray прокси (если включить)" "loopback: xray API of the egress (if enabled)")"
            ;;
        gowarp)
            echo "tcp|40000|must|$(bi "loopback: SOCKS5 WARP (сам продукт занятость не проверяет)" "loopback: WARP SOCKS5 (the product itself never checks it)")"
            ;;
        goamnezia)
            # Как на первом экране мастера goAmnezia pro 1.0: Ленивый pro, pro,
            # Semi-pro, Lite. Режимам с сайтом TCP 80 и 443 обязательны (так
            # решает и его preflight_modes); без домена сайт встаёт на IP с
            # самоподписанным сертификатом — порты те же. Pro — это AmneziaWG
            # на UDP 443: мастер без этого порта ставит Semi-pro («Режим Pro
            # без UDP/443 невозможен»), поэтому для pro порт обязателен, а
            # Ленивому pro — замечание: он сам встанет Semi-pro. В Lite TCP
            # не нужен вовсе: сайта нет, порты AmneziaWG случайные.
            case "$mode" in
                lazy|pro|lite_site)
                    echo "tcp|443|must|$(bi "nginx: сайт на домене с сертификатом Let's Encrypt" "nginx: site on the domain with a Let's Encrypt certificate")"
                    echo "tcp|80|must|$(bi "nginx: проверка Let's Encrypt и редирект на https" "nginx: Let's Encrypt challenge and https redirect")"
                    ;;
            esac
            case "$mode" in
                pro)  echo "udp|443|must|$(bi "AmneziaWG на UDP 443: без него pro невозможен, встанет только Semi-pro" "AmneziaWG on UDP 443: pro is impossible without it, only Semi-pro installs")" ;;
                lazy) echo "udp|443|soft|$(bi "AmneziaWG 2.0 на UDP 443; занят — Ленивый pro встанет Semi-pro" "AmneziaWG 2.0 on UDP 443; if taken, Lazy pro ends up as Semi-pro")" ;;
            esac
            echo "tcp|1985|soft|$(bi "loopback: веб-панель (1984 занят goTelegram pro)" "loopback: admin panel (1984 belongs to goTelegram pro)")"
            echo "tcp|1986|info|$(bi "loopback: MCP по HTTP, по умолчанию выключен" "loopback: MCP over HTTP, off by default")"
            case "$mode" in
                lazy|pro|lite_site)
                    echo "tcp|1987|info|$(bi "loopback: страницы подключения, с первой страницей" "loopback: connection pages, from the first page on")" ;;
            esac
            ;;
    esac
}

# prod_ports_opt <id> — порты дополнительных функций, которые встают не при
# установке, а когда их включают в меню самого продукта. Проверка портов и
# карта портов их показывают, строка «НУЖНЫ» в карточке — нет: продукту они
# для установки не нужны. Уровень всегда info. goKaskad pro 3 (ветка dev)
# занятый порт видит сам: протоколу шлюза берёт другой свободный, сайт на
# занятый 443 не встаёт. Сняты с ядра 3.3.3: panel/conf.py,
# gw/inbounds/{wg,ocserv,openvpn,socks5,vless,accel,l2tp,ikev2}.py,
# site/front.py, ipcert/http01.py. Случайные порты (AmneziaWG, открытая
# панель) и внутренние на 127.0.0.1 (xray шлюза) — не строки таблицы.
prod_ports_opt() {
    case "$1" in
        gokaskad)
            echo "tcp|1980|info|$(bi "3.x, loopback: веб-панель (если включить)" "3.x, loopback: web panel (if enabled)")"
            echo "tcp|443|info|$(bi "3.x: VLESS шлюза и сайт на домене (если включить; занят — VLESS на 8443, сайт не встаёт)" "3.x: gateway VLESS and the domain site (if enabled; busy — VLESS on 8443, no site)")"
            echo "tcp|8443|info|$(bi "3.x, шлюз: VLESS, когда 443 занят (если включить)" "3.x, gateway: VLESS when 443 is busy (if enabled)")"
            echo "tcp|80|info|$(bi "3.x: сертификат на IP при быстрой настройке, сайт на домене (если включить)" "3.x: IP certificate in the quick setup, the domain site (if enabled)")"
            echo "udp|51820|info|$(bi "3.x, шлюз: WireGuard по умолчанию (если включить; занят — другой)" "3.x, gateway: WireGuard default (if enabled; busy — another)")"
            echo "tcp|4443|info|$(bi "3.x, шлюз: OpenConnect по умолчанию (если включить; занят — другой)" "3.x, gateway: OpenConnect default (if enabled; busy — another)")"
            echo "udp|4443|info|$(bi "3.x, шлюз: OpenConnect по умолчанию (если включить; занят — другой)" "3.x, gateway: OpenConnect default (if enabled; busy — another)")"
            echo "udp|1194|info|$(bi "3.x, шлюз: OpenVPN по умолчанию (если включить; занят — другой)" "3.x, gateway: OpenVPN default (if enabled; busy — another)")"
            echo "tcp|1080|info|$(bi "3.x, шлюз: SOCKS5 по умолчанию (если включить; занят — другой)" "3.x, gateway: SOCKS5 default (if enabled; busy — another)")"
            echo "udp|1080|info|$(bi "3.x, шлюз: SOCKS5 по умолчанию (если включить; занят — другой)" "3.x, gateway: SOCKS5 default (if enabled; busy — another)")"
            echo "tcp|4433|info|$(bi "3.x, шлюз: SSTP по умолчанию (если включить; занят — другой)" "3.x, gateway: SSTP default (if enabled; busy — another)")"
            echo "udp|500|info|$(bi "3.x, шлюз: IKEv2 и L2TP/IPsec, постоянный (если включить)" "3.x, gateway: IKEv2 and L2TP/IPsec, fixed (if enabled)")"
            echo "udp|4500|info|$(bi "3.x, шлюз: IKEv2 и L2TP/IPsec, постоянный (если включить)" "3.x, gateway: IKEv2 and L2TP/IPsec, fixed (if enabled)")"
            echo "udp|1701|info|$(bi "3.x, шлюз: L2TP, постоянный (если включить)" "3.x, gateway: L2TP, fixed (if enabled)")"
            echo "tcp|1723|info|$(bi "3.x, шлюз: PPTP, постоянный (если включить)" "3.x, gateway: PPTP, fixed (if enabled)")"
            ;;
    esac
}

# Продукту нужен режим? Порты goVLESS и goTelegram зависят от Lite/pro.
# Режимы продукта, от требовательного к скромному: проверка идёт по этому
# порядку, и первый прошедший даёт ответ «готов». Двумя режимами список не
# ограничен — у goAmnezia pro их три, и «pro или Lite» про него было бы враньём.
prod_modes() {
    case "$1" in
        govless|gotelegram) printf 'pro lite' ;;
        goamnezia)          printf 'pro lite_site lite' ;;
        *)                  printf '' ;;
    esac
}

# prod_mode_choices <id> — что предлагается в вопросе о режиме, в порядке
# первого экрана мастера продукта. У goAmnezia pro первым идёт Ленивый pro:
# это не режим, а сценарий установки (итог — pro, при занятом UDP 443 —
# Semi-pro), поэтому в prod_modes его нет: config.json его не хранит, а
# готовность считается по режимам, которые в итоге встают.
prod_mode_choices() {
    case "$1" in
        goamnezia) printf 'lazy pro lite_site lite' ;;
        *)         prod_modes "$1" ;;
    esac
}

# prod_mode_default <id> — ответ на Enter в вопросе о режиме. У goAmnezia pro
# — Lite, как в его мастере («Enter — 4, Lite»): ни домена, ни TCP-портов.
# У остальных — первый, самый требовательный.
prod_mode_default() {
    local m=""
    case "$1" in
        goamnezia) printf 'lite'; return 0 ;;
    esac
    read -r m _ <<<"$(prod_modes "$1")"
    printf '%s' "$m"
}

# mode_ok <id> <режим> — слово из вопроса о режиме этого продукта. Опечатка в
# `--check goamnezia Pro` иначе проверила бы пустой набор портов и ответила
# «всё свободно». У продукта без режимов слово ни на что не влияет.
mode_ok() {
    prod_has_modes "$1" || return 0
    case " $(prod_mode_choices "$1") " in *" $2 "*) return 0 ;; esac
    return 1
}

# mode_arg <id> <режим> — режим из командной строки: пустой годится (спросим
# или возьмём из настроек продукта), чужое слово — отказ с перечнем.
mode_arg() {
    [ -z "$2" ] && return 0
    mode_ok "$1" "$2" && return 0
    err "$(bi "У $(prod_name "$1") нет режима «$2». Есть: $(prod_mode_choices "$1")." "$(prod_name "$1") has no mode '$2'. Available: $(prod_mode_choices "$1").")"
    return 1
}
prod_has_modes() { [ -n "$(prod_modes "$1")" ]; }

# ref_arg <id> <ветка> — ветка из командной строки, как mode_arg для режима.
# 3.x goKaskad pro пишет её в свои настройки: опечатка сломала бы потом
# обновление в самом продукте, а не только эту установку.
ref_arg_known() {
    local r
    for r in $(prod_refs "$1"); do [ "$r" = "$2" ] && return 0; done
    return 1
}
ref_arg() {
    [ -z "$2" ] && return 0
    ref_arg_known "$1" "$2" && return 0
    err "$(bi "У $(prod_name "$1") нет ветки «$2». Есть: $(prod_refs "$1")." "$(prod_name "$1") has no branch '$2'. Available: $(prod_refs "$1").")"
    return 1
}

mode_name() {
    case "$1" in
        pro)       printf 'pro' ;;
        lite)      printf 'Lite' ;;
        # Названия — как у goAmnezia pro с 0.6.0 (Semi-Pro, Ленивый Pro), но
        # «pro» строчными, как везде в goInstaller.
        lite_site) printf 'Semi-pro' ;;
        lazy)      bi "Ленивый pro" "Lazy pro" ;;
        *)         printf '%s' "$1" ;;
    esac
}

mode_desc() {
    local id="$1" m="$2"
    case "$id:$m" in
        goamnezia:lazy) bi "только домен, остальное сделает продукт и режим больше не спросит; UDP 443 занят — встанет Semi-pro" "just a domain, the product does the rest and does not ask the mode again; UDP 443 taken — it becomes Semi-pro" ;;
        *:pro)
            case "$id" in
                goamnezia) bi "сайт на TCP 443, AmneziaWG на UDP 443: нужны домен, TCP 80 и 443, UDP 443" "site on TCP 443, AmneziaWG on UDP 443: needs a domain, TCP 80 and 443, UDP 443" ;;
                *)         bi "домен, сертификат, сайт-маска: 443 и 80" "domain, certificate, mask site: 443 and 80" ;;
            esac ;;
        goamnezia:lite_site) bi "VPN и сайт: сайт на TCP 443 и 80, AmneziaWG на своих портах" "VPN and site: site on TCP 443 and 80, AmneziaWG on its own ports" ;;
        goamnezia:lite)      bi "только VPN: TCP-порты не нужны, AmneziaWG на своих портах" "VPN only: no TCP ports, AmneziaWG on its own ports" ;;
        *:lite)              bi "без домена: только 443" "no domain: 443 only" ;;
    esac
}

# ── проверка перед установкой ───────────────────────────────────────────
# Итог в PF_MUST / PF_SOFT (счётчики) и PF_LINES (для теста и --check).
# PF_OSMUST — сколько из PF_MUST дала ОС: отказ только из-за системы итог
# называет системой, а не советует освобождать порты.
PF_MUST=0; PF_SOFT=0; PF_OSMUST=0; PF_LINES=""
_pf_add() { PF_LINES+="$1"$'\n'; }

preflight() {
    local id="$1" mode="${2:-pro}" line proto port level what holders h proc pid owner addr
    local self_reinstall="no" osl
    PF_MUST=0; PF_SOFT=0; PF_OSMUST=0; PF_LINES=""
    # Для экрана «Аркады»: строки таблицы «порт|ok|bad|note|info|что это|кто
    # держит» и сообщения правил. Печать при этом прежняя.
    PF_ROWS=(); PF_MSGS=()
    scan_listeners
    # Контейнеры — здесь, а не только внутри $(port_holders …): там это
    # подоболочка, и причина отказа docker (DOCKER_ERR) до строки таблицы
    # не доходила.
    scan_docker

    print_header "$(bi "Проверка перед установкой" "Pre-install check"): $(prod_name "$id")$( prod_has_modes "$id" && printf ' (%s)' "$(mode_name "$mode")")"

    # ОС
    PF_CAPTURE=1
    while IFS= read -r osl; do
        [ -n "$osl" ] || continue
        level="${osl%%|*}"; what="${osl#*|}"
        if [ "$level" = "must" ]; then err "$what"; PF_MUST=$((PF_MUST+1)); PF_OSMUST=$((PF_OSMUST+1)); _pf_add "os|must|$what"
        else warn "$what"; PF_SOFT=$((PF_SOFT+1)); _pf_add "os|soft|$what"; fi
    done < <(prod_os_check "$id")
    PF_CAPTURE=""

    if prod_installed "$id"; then
        local free
        if free=$(prod_free_edition "$id"); then
            say "$(bi "Стоит бесплатный ${free} из инструкции — $(prod_name "$id") встанет поверх него; порты ${free} считаются своими." "The free ${free} from the guide is installed — $(prod_name "$id") installs over it; the ${free} ports count as its own.")"
        else
            say "$(bi "$(prod_name "$id") уже установлен — это переустановка/обновление; его собственные порты не считаются занятыми." "$(prod_name "$id") is already installed — this is a reinstall/upgrade; its own ports do not count as busy.")"
        fi
        self_reinstall="yes"
    fi

    # Порты
    echo ""
    # Колонка статуса — один символ: ✓ свободен/свой, ✗ занят (препятствие),
    # ! занят (замечание), · занят (к сведению). Слова со статусом — в
    # хвосте строки: printf '%-9s' считает БАЙТЫ, и кириллица разъезжается.
    # Вся таблица — в stderr, как и say/warn/err: иначе через пайп строки
    # двух потоков перемешиваются.
    echo -e "  ${DIM}$(bi "✓ свободен или свой   ✗ занят, препятствие   ! занят, замечание   · занят, к сведению" "✓ free or own   ✗ busy, blocker   ! busy, remark   · busy, note")${NC}" >&2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS='|' read -r proto port level what <<<"$line"
        holders=$(port_holders "$proto" "$port")
        if [ -z "$holders" ]; then
            printf "  %-11s ${GREEN}✓${NC}  %s\n" "$port/$proto" "$what" >&2
            _pf_add "$port/$proto|free|$level"
            PF_ROWS+=("$port/$proto|ok|$what|")
            continue
        fi
        # Берём первого держателя — для решения его достаточно.
        h="${holders%%$'\n'*}"
        IFS='|' read -r proc pid owner addr <<<"$h"
        # Чужую панель 3X-UI установщик goVLESS pro не сносит, а берёт себе:
        # xray на её портах остаётся тем же. Что при этом меняется — в
        # правилах соседства ниже.
        # Прежний MTProxy установщик goTelegram pro останавливает сам (миграция
        # v1): порт достаётся telemt.
        if [ "$id" = gotelegram ] && [ "$owner" = mtproxy ]; then
            printf "  %-11s ${GREEN}✓${NC}  %s ${DIM}— $(bi "прежний MTProxy, его остановит" "earlier MTProxy, stopped by") $(prod_name "$id"): %s${NC}\n" "$port/$proto" "$what" "$proc" >&2
            _pf_add "$port/$proto|own|$level|$owner"
            PF_ROWS+=("$port/$proto|ok|$what|$(bi "прежний MTProxy" "earlier MTProxy")")
            continue
        fi
        if [ "$id" = govless ] && [ "$owner" = xui ]; then
            printf "  %-11s ${GREEN}✓${NC}  %s ${DIM}— $(bi "панель 3X-UI, её возьмёт" "3X-UI panel, taken over by") $(prod_name "$id"): %s${NC}\n" "$port/$proto" "$what" "$proc" >&2
            _pf_add "$port/$proto|own|$level|$owner"
            PF_ROWS+=("$port/$proto|ok|$what|$(bi "панель 3X-UI" "3X-UI panel")")
            continue
        fi
        # «Свой» — только при переустановке. Если продукт по маркерам не
        # стоит, а его юниты держат порты, это остатки прежней установки,
        # и их надо назвать: установщик продукта на них споткнётся.
        if [ "$owner" = "$id" ] && [ "$self_reinstall" = "yes" ]; then
            printf "  %-11s ${GREEN}✓${NC}  %s ${DIM}— $(bi "свой" "own"): %s${NC}\n" "$port/$proto" "$what" "$proc" >&2
            _pf_add "$port/$proto|own|$level|$owner"
            PF_ROWS+=("$port/$proto|ok|$what|$(bi "свой: " "own: ")$proc")
            continue
        fi
        local who
        if [ "$proc" = docker-proxy ] && [ "$self_reinstall" = yes ] && prod_uses_docker "$id"; then
            # Порт держит контейнер, а чей — docker не сказал (не ответил или
            # отказал). Продукт стоит и сам держит свои порты в контейнерах:
            # при его обновлении это почти наверняка его же контейнер, и
            # запрещать обновление из-за него нельзя. Причину называем.
            who="docker-proxy ($(bi "контейнер не опознан, при обновлении $(prod_name "$id") это, скорее всего, его собственный" "container not identified; when updating $(prod_name "$id") it is most likely its own")${DOCKER_ERR:+; docker: $DOCKER_ERR})"
            [ "$level" = must ] && level=soft
        elif [ "$owner" = "$id" ] && [ "${proc#docker:}" != "$proc" ]; then
            # Контейнер AmneziaWG приложения Amnezia (или прежней установки):
            # первый экран мастера goAmnezia pro предлагает подхватить его
            # вместе с людьми, Ленивый pro подхватывает без вопроса, и порт
            # остаётся за тем же контейнером. Поэтому это замечание, а не
            # препятствие; откажется человек от подхвата — pro без UDP 443
            # не встанет, и это скажет уже сам мастер.
            who="$proc ($(bi "контейнер AmneziaWG уже на машине — $(prod_name "$id") предложит подхватить его вместе с людьми" "an AmneziaWG container is already here — $(prod_name "$id") offers to adopt it along with its users"))"
            [ "$level" = must ] && level=soft
        elif [ "$owner" = "$id" ]; then who="$proc ($(bi "остатки прежней установки" "leftovers of a previous install") $(prod_name "$owner"))"
        elif [ "$owner" = "$proc" ] || [ "$owner" = "system" ] || [ "$owner" = "nginx" ]; then who="$proc"
        else who="$proc → $(prod_name "$owner")"; fi
        local whou="$who"
        [ -n "$pid" ] && who="$who, pid $pid"
        case "$level" in
            must) PF_ROWS+=("$port/$proto|bad|$what|$whou") ;;
            soft) PF_ROWS+=("$port/$proto|note|$what|$whou") ;;
            *)    PF_ROWS+=("$port/$proto|info|$what|$whou") ;;
        esac
        case "$level" in
            must)
                printf "  %-11s ${RED}✗${NC}  %s ${RED}— $(bi "занят" "held by"): %s${NC}\n" "$port/$proto" "$what" "$who" >&2
                PF_MUST=$((PF_MUST+1)); _pf_add "$port/$proto|busy|must|$owner|$proc" ;;
            soft)
                printf "  %-11s ${YELLOW}!${NC}  %s ${YELLOW}— $(bi "занят" "held by"): %s${NC}\n" "$port/$proto" "$what" "$who" >&2
                PF_SOFT=$((PF_SOFT+1)); _pf_add "$port/$proto|busy|soft|$owner|$proc" ;;
            info)
                printf "  %-11s ${DIM}·  %s — $(bi "занят" "held by"): %s${NC}\n" "$port/$proto" "$what" "$who" >&2
                _pf_add "$port/$proto|busy|info|$owner|$proc" ;;
        esac
    done < <(prod_ports "$id" "$mode"; prod_ports_opt "$id")
    echo "" >&2

    # Особые правила соседства — то, чего таблица портов не выражает.
    PF_CAPTURE=1
    preflight_extra "$id" "$mode"
    PF_CAPTURE=""

    # Итог
    if [ "$PF_MUST" -gt 0 ] && [ "$PF_MUST" -eq "$PF_OSMUST" ]; then
        err "$(bi "Ставить нельзя: на этой системе $(prod_name "$id") не ставится — см. выше." "Cannot install: $(prod_name "$id") does not install on this system — see above.")"
        osup_hint_ok "$id" && say "$(osup_hint_text)"
        return 1
    elif [ "$PF_MUST" -gt 0 ]; then
        err "$(bi "Ставить нельзя: препятствий — ${PF_MUST}. Снимите препятствия выше и запустите проверку снова." "Cannot install: ${PF_MUST} blocker(s). Remove the blockers above and re-run the check.")"
        return 1
    elif [ "$PF_SOFT" -gt 0 ]; then
        warn "$(bi "Препятствий нет, замечаний — ${PF_SOFT}. Установщик продукта предложит запасные варианты." "No blockers, ${PF_SOFT} remark(s). The product installer will offer fallbacks.")"
        return 2
    fi
    ok "$(bi "Порты свободны, требования выполнены." "Ports are free, requirements are met.")"
    return 0
}

# Правила, которые видно только из кода соседей.
preflight_extra() {
    local id="$1" mode="$2" h owner proc
    case "$id" in
        govless)
            if [ "$mode" = "pro" ]; then
                h=$(port_holders tcp 443 | head -1)
                if [ -n "$h" ]; then
                    IFS='|' read -r proc _ owner _ <<<"$h"
                    if [ "$owner" != "govless" ] && [ "$owner" != "xui" ]; then
                        err "$(bi "goVLESS pro в режиме pro на шаге 8 УБИВАЕТ любой не-xray процесс на 443 без вопроса (fuser -k). Сейчас там ${proc} ($(prod_name "$owner")) — он будет снесён." "goVLESS pro in pro mode at step 8 KILLS any non-xray process on 443 without asking (fuser -k). Right now that is ${proc} ($(prod_name "$owner")) — it would be taken down.")"
                        _pf_add "rule|must|govless-kills-443|$owner"
                        # Уже посчитано как must по таблице; второй раз не считаем.
                    fi
                fi
            fi
            # Чужая панель 3X-UI: установщик оставляет её (xui_already_installed),
            # при неудачном входе задаёт ей новые логин и пароль
            # (recover_panel_login), а подключение на 443 забирает, только если
            # оно того же вида, что режим: Reality для Lite, TLS для Pro
            # (reality_inbound_serving / tls_inbound_serving). Иное на 443 —
            # и своё подключение он создать не сможет.
            if govless_foreign_panel; then
                local kind=Reality; [ "$mode" = "pro" ] && kind=TLS
                warn "$(bi "Панель 3X-UI поставлена не $(prod_name govless): по другой инструкции или вручную. Установщик оставит её и возьмёт себе, а если не сможет войти, задаст ей новые логин и пароль. Готовое подключение ${kind} на 443 он заберёт, а подключение другого вида на этом порту помешает автонастройке: его придётся удалить в панели." "The 3X-UI panel was not installed by $(prod_name govless): another guide or by hand. The installer keeps it and takes it over, and if it cannot log in it sets a new panel login and password. An existing ${kind} inbound on 443 is taken over, an inbound of any other kind on that port blocks the auto-setup: delete it in the panel.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|govless-foreign-panel|xui"
            fi
            if prod_installed gokaskad && [ -f /etc/kaskad/egress/config.json ]; then
                warn "$(bi "У goKaskad pro включён прокси для API Telegram на 10808/10851 — те же порты возьмёт прокси goVLESS pro. Включать можно только один." "goKaskad pro has its Telegram API egress on 10808/10851 — the goVLESS pro egress takes the same ports. Only one can be enabled.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|egress-ports-shared|gokaskad"
            fi
            ;;
        gotelegram)
            # Контейнер mtproto-proxy: установщик pro находит его сам
            # (detect_v1_installation), спрашивает и останавливает — сразу, до
            # дисклеймера и выбора режима. Секрет mtg в telemt не переносится.
            scan_docker
            if grep -q '|mtproto-proxy$' <<<"$DOCKER_PORTS"; then
                warn "$(bi "На сервере прежний MTProxy на mtg (контейнер mtproto-proxy): бесплатная версия из инструкции или goTelegram pro первой версии. Установщик $(prod_name gotelegram) сам предложит его остановить. Секрет не переносится, клиентам понадобится новая ссылка. Старый прокси остановится сразу после ответа «да», ещё до выбора режима." "An earlier MTProxy on mtg is here (container mtproto-proxy): the free edition from the guide or goTelegram pro v1. The $(prod_name gotelegram) installer offers to stop it itself. The secret is not carried over, clients need a new link. The old proxy stops right after you answer yes, before the mode choice.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|gotelegram-old-mtproxy|mtproxy"
            fi
            h=$(port_holders tcp 443 | head -1)
            if [ -n "$h" ]; then
                IFS='|' read -r proc _ owner _ <<<"$h"
                case "$owner" in
                    govless|xui)
                        warn "$(bi "443 держит xray $(prod_name "$owner"). Совместить их можно только вручную: shared-443 (nginx stream + ssl_preread) включается из меню goTelegram pro ПОСЛЕ установки, а установка требует свободный 443." "443 is held by the $(prod_name "$owner") xray. They coexist only manually: shared-443 (nginx stream + ssl_preread) is enabled from the goTelegram pro menu AFTER install, and the install needs 443 free.")"
                        _pf_add "rule|info|shared443-hint|$owner" ;;
                    godns)
                        warn "$(bi "443 держит dnsdist goDNS pro (DoH на 443). Перенесите DoH goDNS pro на 4443 в его меню «Изменить порты» — тогда 443 освободится." "443 is held by the goDNS pro dnsdist (DoH on 443). Move the goDNS pro DoH to 4443 via its 'Change ports' menu — that frees 443.")"
                        _pf_add "rule|info|godns-doh-443|godns" ;;
                    goamnezia)
                        warn "$(bi "443 держит nginx goAmnezia pro. Его сайт можно выключить, переставив goAmnezia pro в режим Lite (только VPN): AmneziaWG работает по UDP и TCP 443 не занимает." "443 is held by the goAmnezia pro nginx. Its site can be dropped by switching goAmnezia pro to Lite mode (VPN only): AmneziaWG works over UDP and does not take TCP 443.")"
                        _pf_add "rule|info|goamnezia-site-443|goamnezia" ;;
                esac
            fi
            ;;
        godns)
            # 443 занят чужим — на стандартном порту goDNS pro не встанет, но
            # это не отказ: DoH уйдёт на 4443 (или следующий свободный), DoT
            # останется на 853. Сказать это прямо: строка «· к сведению» в
            # таблице и «готов» в меню читались как «встанет на 443».
            h=$(port_holders tcp 443 | head -1)
            if [ -n "$h" ]; then
                IFS='|' read -r proc _ owner _ <<<"$h"
                if [ "$owner" != godns ]; then
                    local who443="$proc"
                    case "$owner" in govless|gotelegram|goamnezia|gokaskad|gowarp|xui|mtproxy) who443="$(prod_name "$owner")" ;; esac
                    warn "$(bi "443 занят (${who443}): на стандартном порту $(prod_name godns) не встанет — встанет рядом: DoH на 4443 или следующем свободном, DoT на 853. iPhone и Mac получат профиль DoT: DoH не на 443 они не принимают." "443 is taken (${who443}): $(prod_name godns) cannot use the standard port — it installs beside it: DoH on 4443 or the next free port, DoT on 853. iPhone and Mac get a DoT profile: they do not accept DoH off 443.")"
                    PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|godns-beside-443|$owner"
                fi
            fi
            if ! prod_installed godns && ! prod_installed govless && ! prod_installed gotelegram \
               && ! ls -d "${GOINST_LE_ROOT:-/etc/letsencrypt}"/live/*/ >/dev/null 2>&1; then
                warn "$(bi "Сертификата на машине нет: ни goVLESS pro, ни goTelegram pro, ни Let's Encrypt. goDNS pro предложит выпустить свой — для этого нужны домен с A-записью и свободный :80." "No certificate on this machine: no goVLESS pro, no goTelegram pro, no Let's Encrypt. goDNS pro will offer to issue its own — that needs a domain with an A record and a free :80.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|no-cert|"
            fi
            ;;
        gokaskad)
            if [ -f /etc/govless/egress/config.json ] || systemctl is-enabled govless-egress.service >/dev/null 2>&1; then
                warn "$(bi "У goVLESS pro включён прокси для API Telegram на 10808/10851 — прокси goKaskad pro возьмёт те же порты. Включать можно только один." "goVLESS pro has its Telegram API egress on 10808/10851 — the goKaskad pro egress takes the same ports. Only one can be enabled.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|egress-ports-shared|govless"
            fi
            say "$(bi "Каскад работает через DNAT в PREROUTING: правило на порт, где что-то слушает локально (443 у xray/telemt, 853 у goDNS pro), молча перехватит внешний трафик у этого слушателя. Порты каскада выбирайте из свободных." "The cascade uses DNAT in PREROUTING: a rule on a port with a local listener (443 of xray/telemt, 853 of goDNS pro) silently hijacks external traffic from it. Pick cascade ports among free ones.")"
            ;;
        goamnezia)
            # Главное, что надо сказать про этот продукт: занятый TCP 443 не
            # мешает VPN. Сайт без него не поставить, а AmneziaWG живёт на
            # UDP, и UDP 443 у соседей по серии не занят никем.
            h=$(port_holders tcp 443 | head -1)
            if [ -n "$h" ] && [ "$mode" != "lite" ]; then
                IFS='|' read -r proc _ owner _ <<<"$h"
                if [ "$owner" != "goamnezia" ]; then
                    # UDP 443 в Lite не обещаем: AmneziaWG на UDP 443 — это
                    # и есть pro, а ему нужен сайт на TCP 443.
                    say "$(bi "TCP 443 держит ${proc}. Это мешает только сайту: в режиме Lite (только VPN) goAmnezia pro ставится рядом — AmneziaWG работает по UDP на своих портах." "TCP 443 is held by ${proc}. That blocks only the site: in Lite mode (VPN only) goAmnezia pro installs alongside — AmneziaWG works over UDP on its own ports.")"
                    _pf_add "rule|info|goamnezia-lite-alongside|$owner"
                fi
            fi
            if ! have_cmd docker && [ -z "${GOINST_FAKE_CMDS+x}" ]; then
                say "$(bi "Docker не установлен — goAmnezia pro поставит его сам." "Docker is not installed — goAmnezia pro installs it itself.")"
            fi
            # Штатный сайт Debian удаляется без спроса: сосед, который на него
            # рассчитывает, перестанет отвечать.
            if [ "$mode" != "lite" ] && [ -e "${GOINST_NGINX_ROOT:-/etc/nginx}/sites-enabled/default" ]; then
                warn "$(bi "goAmnezia pro удалит /etc/nginx/sites-enabled/default без вопроса: сайт по умолчанию перестанет отвечать." "goAmnezia pro removes /etc/nginx/sites-enabled/default without asking: the default site stops answering.")"
                PF_SOFT=$((PF_SOFT+1)); _pf_add "rule|soft|nginx-default-removed|"
            fi
            ;;
        gowarp)
            if have_cmd warp-cli && ! prod_installed gowarp; then
                err "$(bi "На машине уже есть warp-cli (пакет cloudflare-warp), поставленный не goWARP pro. Второй warp-svc на одной машине невозможен — сначала удалите существующий." "warp-cli (the cloudflare-warp package) is already here, not installed by goWARP pro. A second warp-svc on one machine is impossible — remove the existing one first.")"
                PF_MUST=$((PF_MUST+1)); _pf_add "rule|must|warp-cli-foreign|"
            fi
            ;;
    esac
    return 0
}

# ── карта портов ────────────────────────────────────────────────────────
show_ports() {
    local dl dproto dport dname h
    scan_listeners
    scan_docker
    print_header "$(bi "Кто какие порты держит" "Who holds which ports")"
    if [ -z "$LISTENERS" ]; then say "$(bi "Слушателей нет (или ss недоступен)." "No listeners (or ss is unavailable).")"; return 0; fi
    # Заголовок латиницей: %-Ns считает байты, кириллица разъехалась бы.
    printf "  ${DIM}%-5s %-22s %-26s %s${NC}\n" "proto" "address" "process (pid)" "$(bi "→ продукт" "→ product")" >&2
    printf '%s\n' "$LISTENERS" | sort -t'|' -k3,3n -k1,1 | while IFS='|' read -r proto addr port proc pid; do
        [ -n "$port" ] || continue
        local owner label
        owner=$(holder_product "$proc" "$pid")
        case "$owner" in
            govless|gotelegram|godns|gokaskad|gowarp|gocdn) label="${GREEN}$(prod_name "$owner")${NC}" ;;
            system) label="${DIM}$(bi "система" "system")${NC}" ;;
            xui)    label="${YELLOW}$(prod_name xui) ($(bi "без" "without") $(prod_name govless))${NC}" ;;
            mtproxy) label="${YELLOW}$(prod_name mtproxy)${NC}" ;;
            nginx)  label="${DIM}nginx ($(bi "ничей сайт" "no product site"))${NC}" ;;
            *)      label="${YELLOW}$(bi "чужой" "foreign")${NC}" ;;
        esac
        printf "  %-5s %-22s %-26s ${label}\n" "$proto" "${addr:-*}:$port" "${proc:-?}${pid:+ ($pid)}" >&2
    done
    # Контейнеры: при `userland-proxy: false` слушателя на хосте нет вовсе,
    # и в списке выше такой порт не появится.
    if [ -n "$DOCKER_PORTS" ]; then
        while IFS='|' read -r dproto dport dname; do
            [ -n "$dport" ] || continue
            h=$(port_holders "$dproto" "$dport") || h=""
            [ -n "$h" ] && grep -qv '^docker:' <<<"$h" && continue
            printf "  %-5s %-22s %-26s ${GREEN}%s${NC}\n" "$dproto" "0.0.0.0:$dport" "docker: $dname" "$(prod_name "$(container_product "$dname")")" >&2
        done <<<"$DOCKER_PORTS"
    fi
    echo "" >&2
}

# ── ключ доступа ────────────────────────────────────────────────────────
# Один ключ на все закрытые репозитории. Kaskad и goWARP тоже закрытые, но
# у их установщиков нет своей переменной — качаем файл сами.
# Ключ берётся из окружения, а если его там нет — из сохранённого файла.
# Окружение выигрывает: разовый запуск с другим ключом не должен молча
# подменять сохранённый.
TOKEN_FILE="${GOINST_TOKEN_FILE:-${GOINST_DIR}/token}"
BOOSTY_URL="${GOINST_BOOSTY_URL:-https://boosty.to/anten-ka/purchase/3134076?ssource=DIRECT&share=subscription_link}"
CLUB_TOPIC="${GOINST_CLUB_TOPIC:-goinstall}"
TOKEN=""
TOKEN_FROM=""          # env | file | asked
TOKEN_STATUS=""        # ok | bad | denied | nonet | limited | none
TOKEN_DENIED=""        # репозитории, до которых ключ не дотянулся

# ── ожидание ответа GitHub и повторы ────────────────────────────────────
# Было 5 с на соединение, 8 на весь запрос и ни одного повтора. На сервере
# подписчика (6.10) каждый запрос к GitHub шёл 5–9 с и отвечал 200, а
# goInstaller обрывал все шесть проверок ключа и писал «GitHub недоступен»
# при живом GitHub. Заказчик: максимальная отказоустойчивость, и человек
# видит, что происходит и почему.
GH_CT="${GOINST_GH_CONNECT_TIMEOUT:-30}"   # соединение: DNS, TCP, TLS
GH_MT="${GOINST_GH_TIMEOUT:-60}"           # весь запрос, одна попытка
GH_TRIES="${GOINST_GH_TRIES:-4}"           # попыток на запрос
GH_DELAY="${GOINST_GH_RETRY_DELAY:-2}"     # первая пауза, дальше вдвое
GH_PINS=""; GH_PIN_DONE=""
# Куда сообщать о повторах: GH_RETRY_LOG — файл (фоновый опрос, параллельные
# проверки), GH_SAY=1 — сразу на экран (одиночное скачивание). GH_DOWN_FILE —
# метка «сети нет»: запрос, исчерпавший все попытки, ставит её, и следующие
# запросы того же запуска не ждут по кругу, а сразу отвечают тем же.
GH_RETRY_LOG=""; GH_SAY=""; GH_DOWN_FILE=""
GH_GET_CODE=""   # код последнего ответа gh_get (в этой оболочке)
GH_WHAT=""   # что сейчас качаем — в сообщении о повторе, чтобы строки различались

# Медленный DNS сервера добавлял свои секунды к каждому из десятков запросов
# опроса. Если адрес GitHub узнаётся дольше секунды, он узнаётся один раз и
# закрепляется в конфиге curl (resolve) до конца запуска. Только при живом
# IPv4-маршруте: на сервере без IPv4 закреплённый адрес отрезал бы GitHub.
gh_pin_slow_dns() {
    [ -n "$GH_PIN_DONE" ] && return 0
    GH_PIN_DONE=1
    [ -n "${GOINST_TEST:-}" ] && [ -z "${GOINST_PIN_TEST:-}" ] && return 0
    [ -n "${GOINST_HTTP_FIXTURE:-}" ] && return 0
    [ -n "$(ip -4 route show default 2>/dev/null)" ] || [ -n "${GOINST_PIN_TEST:-}" ] || return 0
    local h a t0
    for h in api.github.com raw.githubusercontent.com; do
        _ui_now_ms; t0="$UI_NOW"
        a=$(_net_resolve "$h")
        _ui_now_ms
        case "$a" in *.*.*.*) ;; *) continue ;; esac
        [ $(( UI_NOW - t0 )) -ge 1000 ] && GH_PINS+="resolve = \"${h}:443:${a}\""$'\n'
    done
    return 0
}
# Строки конфига curl для GitHub: ожидание и закреплённые адреса. В группе
# «{ …; } > cfg» — та же оболочка, поэтому закрепление делается один раз.
gh_cfg_net() {
    gh_pin_slow_dns
    printf 'connect-timeout = %s\n' "$GH_CT"
    printf '%s' "$GH_PINS"
}
# Код выхода curl без ответа GitHub → причина словами.
gh_net_reason() {
    case "$1" in
        5)  bi "не отвечает прокси сервера (переменные http_proxy и https_proxy)" "the server's proxy does not answer (http_proxy and https_proxy)" ;;
        6)  bi "сервер не узнаёт адрес api.github.com: не работает DNS (/etc/resolv.conf)" "the server cannot resolve api.github.com: DNS is broken (/etc/resolv.conf)" ;;
        7)  bi "соединение с GitHub не устанавливается: путь закрыт у хостера или фильтром" "no connection to GitHub: the path is closed by the hoster or a filter" ;;
        28) bi "время ожидания вышло: очень медленная сеть, фильтр в пути или размер пакета — goinstall --net" "the wait timed out: a very slow network, a filter on the path or the packet size — goinstall --net" ;;
        35|52|55|56) bi "соединение с GitHub рвётся на полпути: фильтр в пути или размер пакета — goinstall --net" "the GitHub connection breaks midway: a filter on the path or the packet size — goinstall --net" ;;
        60|77) bi "сертификат GitHub не прошёл проверку: неверное время на сервере (date) или нет пакета ca-certificates" "the GitHub certificate failed verification: wrong server time (date) or no ca-certificates package" ;;
        *)  bi "ошибка curl ${1}" "curl error ${1}" ;;
    esac
}

# Сетевой сбой — ответа GitHub не было: такое повторяем. Ответ GitHub
# (200, 304, 401, 403, 404) окончателен — повтор его не изменит, а лимит
# только потратит.
_gh_net_rc() { case "$1" in 5|6|7|16|18|28|35|52|55|56|92) return 0 ;; esac; return 1; }

gh_retry_note() {  # gh_retry_note <код curl> <попытка> <пауза>
    [ -n "$GH_RETRY_LOG" ] && printf '%s %s %s\n' "$1" "$(( $2 + 1 ))" "$GH_TRIES" >> "$GH_RETRY_LOG" 2>/dev/null
    [ "$GH_SAY" = 1 ] && warn "${GH_WHAT:+${GH_WHAT}: }$(bi "попытка ${2} из ${GH_TRIES} не удалась: $(gh_net_reason "$1"). Повтор через ${3} с…" "attempt ${2} of ${GH_TRIES} failed: $(gh_net_reason "$1"). Retrying in ${3} s…")"
    return 0
}

# gh_wait_report — дождаться фоновых запросов, по ходу говоря человеку, какая
# идёт попытка и почему: по журналу повторов GH_RETRY_LOG. Иначе на плохой
# сети человек минутами смотрел бы на «Проверяю ключ доступа…».
# Ждём только свои запросы (их PID), а не все фоновые задачи: в «Аркаде» во
# время ввода ключа фоном идёт опрос, и ждать его здесь незачем. Пока на
# экране «Аркада» (UI_ALT=1), строки не печатаем — они легли бы поверх меню.
gh_can_say() { [ "${UI_ALT:-0}" != 1 ]; }
gh_wait_report() {  # gh_wait_report <pid…>
    local shown=1 cur m r p alive
    while :; do
        alive=0
        for p in "$@"; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
        [ "$alive" = 1 ] || break
        if gh_can_say && [ -s "$GH_RETRY_LOG" ]; then
            cur=$(awk '{ if ($2 + 0 > m) { m = $2 + 0; r = $1 } } END { print m + 0, r }' "$GH_RETRY_LOG")
            m="${cur%% *}"; r="${cur#* }"
            if [ "$m" -gt "$shown" ]; then
                shown="$m"
                say "$(bi "Попытка ${m} из ${GH_TRIES}: $(gh_net_reason "$r"). Жду ответа GitHub…" "Attempt ${m} of ${GH_TRIES}: $(gh_net_reason "$r"). Waiting for GitHub…")"
            fi
        fi
        sleep 1
    done
    wait "$@" 2>/dev/null
    return 0
}

# gh_curl <аргументы curl…> — curl к GitHub с повторами. Печатает вывод
# последней попытки (код из -w), отдаёт её код выхода. Временный ответ
# самого GitHub (5xx, 429, 408), видный по -w, тоже повторяется.
gh_curl() {
    local try=1 out rc delay="$GH_DELAY" again
    if [ -n "$GH_DOWN_FILE" ] && [ -s "$GH_DOWN_FILE" ]; then
        printf '000'; return "$(head -1 "$GH_DOWN_FILE" 2>/dev/null || echo 28)"
    fi
    while :; do
        # Сообщения самого curl — в никуда: причину мы говорим словами сами.
        out=$(curl "$@" 2>/dev/null); rc=$?
        again=0
        _gh_net_rc "$rc" && again=1
        case "$out" in 5[0-9][0-9]|429|408) again=1 ;; esac
        [ "$again" = 1 ] || break
        if [ "$try" -ge "$GH_TRIES" ]; then
            # Все попытки — сетевой сбой: сети нет, остальным не ждать.
            _gh_net_rc "$rc" && [ -n "$GH_DOWN_FILE" ] && printf '%s\n' "$rc" > "$GH_DOWN_FILE" 2>/dev/null
            break
        fi
        gh_retry_note "$rc" "$try" "$delay"
        sleep "$delay"; delay=$(( delay * 2 )); try=$(( try + 1 ))
    done
    printf '%s' "$out"
    return "$rc"
}

token_load() {
    local env_tok="${GH_TOKEN:-${GOTELEGRAM_PAT:-${GITHUB_PAT:-${GOINST_TOKEN:-}}}}"
    if [ -n "$env_tok" ]; then TOKEN="$env_tok"; TOKEN_FROM="env"; return 0; fi
    if [ -r "$TOKEN_FILE" ]; then
        TOKEN=$(head -1 "$TOKEN_FILE" 2>/dev/null) || TOKEN=""
        TOKEN="${TOKEN//[[:space:]]/}"
        [ -n "$TOKEN" ] && { TOKEN_FROM="file"; return 0; }
    fi
    TOKEN=""; TOKEN_FROM=""; return 1
}

# Сохраняем так, чтобы ключ не оказался доступен никому, кроме root:
# каталог 0700, файл 0600, режим выставляется ДО записи через umask.
token_save() {
    local dir
    dir=$(dirname "$TOKEN_FILE")
    mkdir -p "$dir" 2>/dev/null || { warn "$(bi "Не удалось создать ${dir} — ключ не сохранён." "Could not create ${dir} — the key is not saved.")"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    ( umask 077; printf '%s\n' "$1" > "$TOKEN_FILE" ) 2>/dev/null || {
        warn "$(bi "Не удалось записать ${TOKEN_FILE} — ключ не сохранён." "Could not write ${TOKEN_FILE} — the key is not saved.")"; return 1; }
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
    return 0
}

token_forget() { rm -f "$TOKEN_FILE" 2>/dev/null || true; }

# Один запрос к GitHub на репозиторий: печатает код ответа. Ключ уходит
# заголовком из конфига 0600, а не аргументом.
_token_probe() {
    local repo="$1" cfg="$2" code
    # Фикстура для набора: строки «owner/repo=код». Иначе ветки «ключ
    # отвергнут», «доступа нет» и «сети нет» проверить нечем, а именно в
    # них живёт весь смысл этой функции.
    local hdr key etag
    local -a cond=()
    if [ -n "${GOINST_HTTP_FIXTURE:-}" ]; then
        code=$(sed -n -E "s#^${repo}=([0-9]+|RL)\$#\1#p" "$GOINST_HTTP_FIXTURE" 2>/dev/null | head -1) || code=""
        printf '%s' "${code:-000}"; return 0
    fi
    # Лимит уже исчерпан — спрашивать незачем: ответ известен заранее.
    gh_limited >/dev/null && { printf 'RL'; return 0; }
    # Условный запрос: 304 приходит только тому, кто прошёл проверку ключа,
    # а в лимит не засчитывается.
    key="token_${repo//[^A-Za-z0-9._-]/_}"; etag="$GH_HTTP_CACHE/$key.etag"
    [ -s "$etag" ] && cond=(-H "If-None-Match: $(head -1 "$etag")")
    hdr=$(mktemp "${TMPDIR:-/tmp}/goinst-hdr.XXXXXX") || { printf '000'; return 0; }
    # Код ответа берём из -w, а не из кода выхода: с опцией fail curl
    # выходит с ошибкой на любой 4xx, и «|| code=000» стирал бы 403 —
    # единственное, по чему лимит отличается от обрыва сети.
    local rc
    code=$(gh_curl --config "$cfg" -D "$hdr" -o /dev/null -w '%{http_code}' ${cond[@]+"${cond[@]}"} \
           --max-time "${GOINST_TOKEN_TIMEOUT:-$GH_MT}" \
           "https://api.github.com/repos/${repo}"); rc=$?
    [ -n "$code" ] || code="000"
    case "$code" in
        200) mkdir -p "$GH_HTTP_CACHE" 2>/dev/null && chmod 700 "$GH_HTTP_CACHE" 2>/dev/null
             _gh_etag_save "$hdr" "$etag" ;;
        304) code=200 ;;
        403|429) gh_limit_mark "$hdr" && code="RL" ;;
    esac
    rm -f "$hdr"
    # Ответа не было — к коду добавляем код выхода curl: по нему причина.
    [ "$code" = 000 ] && [ "$rc" -ne 0 ] && code="000/${rc}"
    printf '%s' "${code:-000}"
}

# token_check — проверяет, ЧИТАЕТ ли ключ наши репозитории. Именно читает:
# «ключ валиден» и «ключ открывает нужное» — разные утверждения, и второе
# единственное, которое здесь имеет смысл.
#   ok     — хотя бы один репозиторий отдал 200 и отказов нет
#   denied — ключ принят, но до части репозиториев не дотянулся (404/403)
#   bad    — ключ отвергнут (401) или закрыт для всего
#   nonet  — до GitHub не достучались: ключ не виноват, трогать его нельзя
token_check() {
    local id repo cfg code ok=0 denied=0 neterr=0 unauth=0 limited=0 tmp
    TOKEN_STATUS=""; TOKEN_DENIED=""; TOKEN_NETRC=""
    [ -n "$TOKEN" ] || { TOKEN_STATUS="none"; return 1; }
    if [ -n "${GOINST_NO_NET:-}" ]; then TOKEN_STATUS="ok"; return 0; fi
    command -v curl >/dev/null 2>&1 || { TOKEN_STATUS="ok"; return 0; }
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-tok.XXXXXX") || { TOKEN_STATUS="nonet"; return 1; }
    chmod 600 "$cfg"
    { echo 'silent'; echo 'location'; gh_cfg_net
      printf 'header = "Authorization: token %s"\n' "$TOKEN"; } > "$cfg"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/goinst-tokd.XXXXXX") || { rm -f "$cfg"; TOKEN_STATUS="nonet"; return 1; }
    # Шесть проверок идут разом: о повторах каждая пишет в общий журнал, а
    # человеку — одна строка после. Свой журнал и метку «сети нет» берём,
    # только если их не задал вызывающий (фоновый опрос задаёт свои).
    local own_log="" own_down=""
    [ -n "$GH_RETRY_LOG" ] || { GH_RETRY_LOG="$tmp/retries"; own_log=1; }
    [ -n "$GH_DOWN_FILE" ] || { GH_DOWN_FILE="$tmp/down"; own_down=1; }
    local -a pids=()
    for id in "${PRODUCTS[@]}"; do
        repo=$(prod_repo "$id")
        ( GH_SAY=""; printf '%s' "$(_token_probe "$repo" "$cfg")" > "$tmp/$id" ) &
        pids+=("$!")
    done
    if [ -n "$own_log" ]; then gh_wait_report "${pids[@]}"; else wait "${pids[@]}"; fi
    TOKEN_RETRIES=0
    [ -s "$GH_RETRY_LOG" ] && TOKEN_RETRIES=$(wc -l < "$GH_RETRY_LOG" | tr -d ' ')
    local retry_rc=""; [ "$TOKEN_RETRIES" -gt 0 ] && retry_rc=$(awk 'END{print $1}' "$GH_RETRY_LOG")
    [ -n "$own_log" ] && GH_RETRY_LOG=""
    [ -n "$own_down" ] && GH_DOWN_FILE=""
    rm -f "$cfg"
    for id in "${PRODUCTS[@]}"; do
        code=$(cat "$tmp/$id" 2>/dev/null) || code="000"
        case "$code" in
            200) ok=$((ok+1)) ;;
            401) unauth=$((unauth+1)) ;;
            RL)  limited=$((limited+1)) ;;
            403|404) denied=$((denied+1)); TOKEN_DENIED+="$(prod_name "$id") " ;;
            000/*) neterr=$((neterr+1)); TOKEN_NETRC="${code#000/}" ;;
            *)   neterr=$((neterr+1)) ;;
        esac
    done
    rm -rf "$tmp"
    # Исчерпанный лимит — не приговор ключу: GitHub отвечает 403 и так, а
    # ключ исправен и после сброса снова заработает. Раньше такой отказ
    # читался как «ключ не принят»: ключ стирался на каждом сервере клуба,
    # запущенном в этот час.
    if [ "$limited" -gt 0 ]; then TOKEN_STATUS="limited"; return 0; fi
    if [ "$ok" -eq 0 ] && [ "$neterr" -gt 0 ] && [ "$unauth" -eq 0 ] && [ "$denied" -eq 0 ]; then
        TOKEN_STATUS="nonet"; return 1
    fi
    if [ "$unauth" -gt 0 ] || { [ "$ok" -eq 0 ] && [ "$denied" -gt 0 ]; }; then
        [ -n "$own_log" ] && [ "$TOKEN_RETRIES" -gt 0 ] && gh_can_say && say "$(bi "Связь с GitHub неустойчива: ответ получен после повторов (${TOKEN_RETRIES}). Причина сбоев: $(gh_net_reason "$retry_rc")." "The connection to GitHub is unstable: the answer came after retries (${TOKEN_RETRIES}). Cause of the failures: $(gh_net_reason "$retry_rc").")"
        TOKEN_STATUS="bad"; return 1
    fi
    # Ответ получен, но не с первого раза — сказать, что связь неустойчива.
    if [ -n "$own_log" ] && [ "$TOKEN_RETRIES" -gt 0 ] && gh_can_say; then
        say "$(bi "Связь с GitHub неустойчива: ответ получен после повторов (${TOKEN_RETRIES}). Причина сбоев: $(gh_net_reason "$retry_rc")." "The connection to GitHub is unstable: the answer came after retries (${TOKEN_RETRIES}). Cause of the failures: $(gh_net_reason "$retry_rc").")"
    fi
    if [ "$denied" -gt 0 ]; then TOKEN_STATUS="denied"; return 0; fi
    TOKEN_STATUS="ok"; return 0
}

# Где взять ключ. Печатается всегда, когда ключа нет или он не подошёл:
# человек в этот момент не должен идти искать инструкцию.
token_where() {
    echo "" >&2
    echo -e "  ${BOLD}$(bi "Где взять ключ" "Where to get the key")${NC}" >&2
    echo -e "  ${DIM}$(bi "Ключ на чтение выдаётся подписчикам в закрытой группе «anten-ka club»," "The read-only key is given to subscribers in the private «anten-ka club» group,")${NC}" >&2
    echo -e "  ${DIM}$(bi "в ветке" "in the") ${NC}${CYAN}${CLUB_TOPIC}${NC}${DIM}.${NC}" >&2
    echo -e "  $(bi "Подписка" "Subscription"): ${CYAN}${BOOSTY_URL}${NC}" >&2
    echo "" >&2
}

# Спросить ключ и проверить его на месте. Непроверенный ключ сохранять
# нельзя: человек уйдёт с ощущением, что всё настроено, и узнает правду
# в середине установки.
token_prompt() {
    local t attempt=0
    token_where
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt+1))
        if ! IFS= read -rsp "  $(bi "Ключ (ввод скрыт)" "Key (input hidden)"): " t; then echo "" >&2; return 1; fi
        echo "" >&2
        t="${t//[[:space:]]/}"
        # Пустой ответ — это «не сейчас», а не промах. Считать его ошибкой и
        # спрашивать ещё дважды значит держать человека, который всего лишь
        # хотел посмотреть занятые порты.
        if [ -z "$t" ]; then
            say "$(bi "Пропускаю. Ключ можно ввести позже: goinstall --key set" "Skipped. The key can be entered later: goinstall --key set")"
            return 1
        fi
        TOKEN="$t"; TOKEN_FROM="asked"
        say "$(bi "Проверяю ключ…" "Checking the key…")"
        token_check
        case "$TOKEN_STATUS" in
            ok)
                ok "$(bi "Ключ читает репозитории продуктов." "The key reads the product repositories.")"
                token_save "$t" && ok "$(bi "Ключ сохранён в ${TOKEN_FILE} (0600), спрашивать больше не буду." "The key is saved to ${TOKEN_FILE} (0600); it will not be asked again.")"
                return 0 ;;
            denied)
                warn "$(bi "Ключ принят, но не открывает: ${TOKEN_DENIED}" "The key works, but does not open: ${TOKEN_DENIED}")"
                token_save "$t" && ok "$(bi "Ключ сохранён; недостающий доступ спросите в группе." "The key is saved; ask in the group for the missing access.")"
                return 0 ;;
            nonet)
                warn "$(bi "До GitHub не достучаться — ключ проверить нечем. Сохраняю как есть." "GitHub is unreachable — the key cannot be checked. Saving as is.")"
                [ -n "${TOKEN_NETRC:-}" ] && say "$(bi "Причина" "Cause"): $(gh_net_reason "$TOKEN_NETRC"). $(bi "Пробовал ${GH_TRIES} раза на каждый запрос, ожидание до ${GH_MT} с." "Tried ${GH_TRIES} times per request, waiting up to ${GH_MT} s.")"
                token_save "$t"
                return 0 ;;
            limited)
                warn "$(bi "GitHub сейчас не проверяет ключи: исчерпан общий лимит запросов, снова заработает к $(gh_reset_text). Сохраняю ключ как есть." "GitHub is not checking keys right now: the shared request limit is used up until $(gh_reset_text). Saving the key as is.")"
                token_save "$t"
                return 0 ;;
            *)
                err "$(bi "GitHub этот ключ не принял. Проверьте, что скопирован он целиком." "GitHub rejected this key. Check that it was copied in full.")" ;;
        esac
    done
    TOKEN=""; TOKEN_FROM=""
    return 1
}

# Вызывается перед всем, чему ключ нужен.
ensure_token() {
    [ -n "$TOKEN" ] && return 0
    token_load && return 0
    token_prompt
}

# Проверка при запуске. Отсутствие ключа установку не отменяет: проверка
# портов и карта портов работают и без него, а требовать ключ ради того,
# чтобы посмотреть занятые порты, было бы враньём про необходимость.
token_startup() {
    [ -n "${GOINST_NO_TOKEN_CHECK:-}" ] && { [ -n "$TOKEN" ] || token_load; return 0; }
    if [ -z "$TOKEN" ] && ! token_load; then
        say "$(bi "Ключа доступа нет — без него не скачать ни один продукт." "No access key — no product can be downloaded without it.")"
        token_prompt || warn "$(bi "Продолжаю без ключа: доступны проверка портов и карта портов." "Continuing without a key: the port check and the port map still work.")"
        return 0
    fi
    say "$(bi "Проверяю ключ доступа…" "Checking the access key…")"
    token_check
    case "$TOKEN_STATUS" in
        ok)
            ok "$(bi "Ключ действует." "The key works.")"
            # Ключ, принесённый в переменной, сохраняем: иначе установка
            # одной командой работает ровно один раз, а следующий запуск
            # снова спрашивает ключ, который человек уже дал.
            if [ "$TOKEN_FROM" = "env" ] && [ "$TOKEN" != "$(head -1 "$TOKEN_FILE" 2>/dev/null)" ]; then
                token_save "$TOKEN" && ok "$(bi "Ключ сохранён в ${TOKEN_FILE} (0600) — спрашивать не буду." "The key is saved to ${TOKEN_FILE} (0600) — it will not be asked again.")"
            fi ;;
        denied)
            warn "$(bi "Ключ не открывает: ${TOKEN_DENIED}— эти продукты не скачаются." "The key does not open: ${TOKEN_DENIED}— those products cannot be downloaded.")"
            token_where ;;
        nonet)
            warn "$(bi "До GitHub не достучаться. Ключ оставляю как есть — он, скорее всего, ни при чём." "GitHub is unreachable. Keeping the key as is — it is most likely not the cause.")"
            [ -n "${TOKEN_NETRC:-}" ] && say "$(bi "Причина" "Cause"): $(gh_net_reason "$TOKEN_NETRC"). $(bi "Пробовал ${GH_TRIES} раза на каждый запрос, ожидание до ${GH_MT} с." "Tried ${GH_TRIES} times per request, waiting up to ${GH_MT} s.")" ;;
        limited)
            warn "$(bi "GitHub временно не отвечает по ключу клуба: исчерпан общий лимит — 5000 запросов в час на всех. Снова заработает к $(gh_reset_text). Ключ исправен и остаётся на месте." "GitHub is temporarily refusing the club key: its shared limit of 5000 requests an hour for everyone is used up. It works again by $(gh_reset_text). The key is fine and stays in place.")" ;;
        *)
            err "$(bi "Сохранённый ключ больше не работает: GitHub его не принимает." "The saved key no longer works: GitHub rejects it.")"
            token_forget
            TOKEN=""; TOKEN_FROM=""
            token_prompt || warn "$(bi "Продолжаю без ключа: доступны проверка портов и карта портов." "Continuing without a key: the port check and the port map still work.")" ;;
    esac
    return 0
}

prod_needs_token() {
    local v="GOINST_SRC_$1"
    [ -z "${!v:-}" ]
}

# Похоже ли скачанное на скрипт. Проверяем ПЕРВУЮ СТРОКУ, без конвейера.
#
# ГРАБЛИ: здесь стояло `head -c 200 "$f" | grep -q '^#!/'`. Под
# `set -o pipefail` это мина: grep -q выходит на первом совпадении и
# закрывает канал, head получает SIGPIPE, и статус ВСЕГО конвейера
# ненулевой — но только если head не успел дописать. Получалась гонка:
# один и тот же файл то скачивался, то объявлялся «не скриптом». На живом
# сервере из десяти загрузок проходили три.
looks_like_script() {
    local f="$1" first=""
    [ -s "$f" ] || return 1
    IFS= read -r first < "$f" 2>/dev/null || true
    case "$first" in '#!'*) return 0 ;; *) return 1 ;; esac
}

# ref_sha <repo> <ref> <cfg> — голова ветки одним хешем.
#
# ГРАБЛИ, стоившие живой проверки: у raw.githubusercontent на URL ВЕТКИ
# свой кэш (Cache-Control: max-age=300). Сразу после пуша он отдаёт
# ПРЕЖНИЙ файл, и установщик молча ставит старую версию, сообщая новую.
# Замечено на самом goInstaller: свежевыложенный 0.6.0 скачался как 0.5.1.
# Ни `no-cache`, ни `?t=<штамп>` этого не пробивают. Работает одно:
# спросить у API хеш коммита и качать по нему — такие URL неизменяемы.
# Бонусом все файлы приезжают из ОДНОГО коммита, и пуш в середине
# установки не смешает версии.
ref_sha() {
    local repo="$1" ref="$2" cfg="$3" tmp sha=""
    [ -n "${GOINST_NO_SHA:-}" ] && return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-sha.XXXXXX") || return 1
    # Только хеш: полный ответ о коммите — десятки килобайт со списком
    # изменённых файлов (59 КБ на коммите goInstaller), а нужны 40 знаков.
    if gh_get "https://api.github.com/repos/${repo}/commits/${ref}" "$cfg" "$tmp" "application/vnd.github.sha"; then
        IFS= read -r sha < "$tmp" 2>/dev/null || true
        sha="${sha//[^0-9a-f]/}"
    fi
    rm -f "$tmp"
    [ "${#sha}" -eq 40 ] || return 1
    printf '%s' "$sha"
}

# fetch_raw <owner/repo> <ref> <path> <dest>
# Ключ — в конфиг-файле curl с режимом 0600, не в argv.
fetch_raw() {
    local repo="$1" ref="$2" path="$3" dest="$4" cfg url rc sha
    # Скачивание идёт на глазах у человека: о каждом повторе — сразу, и про
    # хеш ветки, и про сам файл.
    local GH_SAY=1 GH_DOWN_FILE="" GH_WHAT=""
    # Метка «сети нет» на одно скачивание: исчерпал попытки запрос хеша —
    # сам файл не ждёт по второму кругу.
    GH_DOWN_FILE=$(mktemp "${TMPDIR:-/tmp}/goinst-down.XXXXXX") || GH_DOWN_FILE=""
    : > "${GH_DOWN_FILE:-/dev/null}" 2>/dev/null
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-curl.XXXXXX") || return 1
    chmod 600 "$cfg"
    {
        echo 'silent'; echo 'location'; echo 'fail'
        gh_cfg_net; echo 'max-time = 180'
        [ -n "$TOKEN" ] && printf 'header = "Authorization: token %s"\n' "$TOKEN"
    } > "$cfg"
    # Качаем по хешу коммита, а не по имени ветки: см. ref_sha.
    GH_WHAT="$(bi "Хеш ветки" "Branch hash") ${ref}"
    if sha=$(ref_sha "$repo" "$ref" "$cfg"); then
        url="https://raw.githubusercontent.com/${repo}/${sha}/${path}"
    else
        url="https://raw.githubusercontent.com/${repo}/${ref}/${path}"
    fi
    GH_WHAT="${path}"
    gh_curl --config "$cfg" -o "$dest" "$url" >/dev/null; rc=$?
    rm -f "$cfg" "${GH_DOWN_FILE:-}"
    if [ "$rc" -ne 0 ] || [ ! -s "$dest" ]; then
        # Ни до какого ответа GitHub дело не дошло: имя, соединение, TLS,
        # обрыв. Ключ тут не проверялся, винить его нельзя.
        if _gh_net_rc "$rc"; then
            err "$(bi "Не скачалось: ${repo}@${ref}/${path}. GitHub не ответил ни на одну из ${GH_TRIES} попыток. Причина: $(gh_net_reason "$rc") (код curl ${rc}). Ключ тут ни при чём." "Download failed: ${repo}@${ref}/${path}. GitHub answered none of ${GH_TRIES} attempts. Cause: $(gh_net_reason "$rc") (curl code ${rc}). The key is not at fault.")"
            return 1
        fi
        err "$(bi "Не скачалось: ${repo}@${ref}/${path}. Проверьте ключ (нужен доступ на чтение к ${repo}), ветку и сеть." "Download failed: ${repo}@${ref}/${path}. Check the key (read access to ${repo} is required), the branch and the network.")"
        return 1
    fi
    # Страховка от страницы ошибки вместо скрипта.
    if ! looks_like_script "$dest"; then
        err "$(bi "Скачанный файл не похож на скрипт (нет shebang) — вероятно, 404 или неверный ключ." "The downloaded file does not look like a script (no shebang) — probably a 404 or a wrong key.")"
        return 1
    fi
    return 0
}

# ── источники продуктов ─────────────────────────────────────────────────
prod_repo() {
    local v="GOINST_REPO_$1"
    if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return; fi
    case "$1" in
        govless)    printf 'anten-ka/goVLESS' ;;
        gotelegram) printf 'anten-ka/gotelegram_pro' ;;
        godns)      printf 'anten-ka/goDNS' ;;
        gokaskad)   printf 'anten-ka/kaskad-pro' ;;
        gowarp)     printf 'anten-ka/go_warp_pro' ;;
        goamnezia)  printf 'anten-ka/goamnezia_pro' ;;
    esac
}
prod_ref() {
    local v="GOINST_REF_$1"
    if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return; fi
    case "$1" in
        godns) printf 'dev' ;;   # на GitHub у goDNS есть только dev
        *)     printf 'main' ;;
    esac
}
# Файл, который надо скачать и запустить.
prod_entry() {
    case "$1" in
        govless)    printf 'bootstrap.sh' ;;
        gotelegram) printf 'bootstrap.sh' ;;
        godns)      printf 'install.sh' ;;
        gokaskad)   printf 'install.sh' ;;
        gowarp)     printf 'warp.sh' ;;
        goamnezia)  printf 'bootstrap.sh' ;;
    esac
}

# stdin: при `curl | bash` он занят самим скриптом — перецепляем на терминал.
reattach_tty() {
    if [ ! -t 0 ] && { true < /dev/tty; } 2>/dev/null; then
        exec < /dev/tty
    fi
}

# Проверка ПОСЛЕ установщика продукта: сменилась ли ветка и та ли версия.
# «✓ Updated» на экране продукта — не доказательство: goVLESS печатал его,
# оставаясь на прежней ветке. С 1.1.0 итог говорит и о коде установщика, и
# о том, что продукт не встал: «Аркада» писала «✓ Проверено, версия —» после
# «Установка не закончена» продукта.
# installer_verdict <продукт> <ветка> [код установщика] — итог установки
# одной проверкой для --install, нумерованного меню и шага «Сверка» «Аркады».
# → PC_WHY (ok|rc|none|free|ref|ver), PC_ST (ok|warn|err), PC_TX — словами,
# PC_GOTV — стоящая версия, PC_RC — код установщика, PC_HAVE=1 — продукт
# стоит (при коде ≠0 на обновлении стоит прежний: «не встал» — неправда). Надпись продукта об успехе доказательством не
# считается: код, стоит ли, не бесплатный ли, ветка и версия.
installer_verdict() {
    local id="$1" ref="$2" rc="${3:-0}" got_ref want_v src free
    PC_WHY=ok; PC_ST=ok; PC_TX=""; PC_GOTV=""; PC_RC=0; PC_HAVE=""
    case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
    PC_RC="$rc"
    prod_installed "$id" && PC_HAVE=1
    if [ "$rc" -ne 0 ]; then
        PC_WHY=rc; PC_ST=err
        PC_TX=$(bi "Установщик $(prod_name "$id") вышел с кодом ${rc}: установка не закончена." "The $(prod_name "$id") installer exited with code ${rc}: the install did not complete.")
        return 1
    fi
    if [ -z "$PC_HAVE" ]; then
        PC_WHY=none; PC_ST=err
        PC_TX=$(bi "$(prod_name "$id") не встал: установщик закончил, а продукта на сервере нет." "$(prod_name "$id") did not install: the installer finished, but the product is not on the server.")
        return 1
    fi
    PC_GOTV=$(prod_version "$id")
    # Клон Lite на месте — pro не встал, что бы ни напечатал загрузчик: до
    # исправления он «обновлял» этот клон из репозитория Lite и запускал Lite.
    # С локальным источником каталог клона не трогается вовсе — тогда молчим.
    src="GOINST_SRC_${id}"
    if [ -z "${!src:-}" ] && free=$(prod_free_edition "$id"); then
        PC_WHY=free; PC_ST=warn
        case "$id" in
            govless) PC_TX=$(bi "Код в /opt/govless-installer по-прежнему от бесплатного Lite: загрузчик $(prod_name "$id") его не заменил, команда govless открывает Lite." "The code in /opt/govless-installer is still the free Lite: the $(prod_name "$id") loader did not replace it, and the govless command opens Lite.") ;;
            *) PC_TX=$(bi "Вместо $(prod_name "$id") по-прежнему бесплатный ${free}: установщик его не заменил, команда $(prod_cmd "$id") открывает бесплатную версию." "The free ${free} is still in place of $(prod_name "$id"): the installer did not replace it, and the $(prod_cmd "$id") command opens the free edition.") ;;
        esac
        return 1
    fi
    [ -n "$ref" ] || return 0
    if got_ref=$(prod_installed_ref "$id" raw) && [ "$got_ref" != "$ref" ]; then
        PC_WHY=ref; PC_ST=warn
        PC_TX=$(bi "Ветка не сменилась: $(prod_name "$id") стоит с ветки ${got_ref}, а выбрана ${ref}." "The branch did not change: $(prod_name "$id") runs from ${got_ref}, but ${ref} was chosen.")
        return 1
    fi
    # Тревога — только если стоит СТАРШЕ кеша: кеш версий для показа без
    # срока, и новее — норма (в ветку пришёл коммит после опроса).
    want_v=$(ver_cache_get "$id" "$ref") || want_v=""
    if [ -n "$want_v" ] && [ -n "$PC_GOTV" ] && ver_newer "$PC_GOTV" "$want_v"; then
        PC_WHY=ver; PC_ST=warn
        PC_TX=$(bi "Стоит версия ${PC_GOTV}, а в ветке ${ref} лежит ${want_v}: установка могла не дойти до конца." "Installed ${PC_GOTV}, but ${ref} has ${want_v}: the install may not have completed.")
        return 1
    fi
    PC_TX=$(bi "Проверено: $(prod_name "$id") стоит с ветки ${ref}${PC_GOTV:+, версия ${PC_GOTV}}." "Verified: $(prod_name "$id") runs from ${ref}${PC_GOTV:+, version ${PC_GOTV}}.")
    return 0
}
# installer_postcheck <продукт> <ветка> [код установщика] — итог текстом.
installer_postcheck() {
    local id="$1" m
    if ! installer_verdict "$@"; then
        if [ "$PC_ST" = err ]; then err "$PC_TX"; else warn "$PC_TX"; fi
        return 1
    fi
    [ -n "$PC_TX" ] && ok "$PC_TX"
    # Ленивый pro — сценарий, а не режим: встаёт pro или, при занятом UDP 443,
    # Semi-pro. Каким он встал, человек узнаёт здесь, не открывая продукт.
    if [ "${MODE:-}" = lazy ] && m=$(prod_installed_mode "$id"); then
        say "$(bi "Ленивый pro встал в режиме" "Lazy pro ended up in mode") $(mode_name "$m")."
    fi
    return 0
}

# Язык для установщика goKaskad pro 3 (KASKAD_LANG): только при первой
# установке. Язык из окружения 3.x ставит выше записанного и запоминает:
# обновление переписало бы язык, выбранный в меню продукта, в панели или в
# боте, а переход с 2.x — русский, который 3.x оставляет сам. Пусто — 3.x
# возьмёт свой (или спросит).
gokaskad_lang_env() {
    prod_installed gokaskad && return 0
    grep -qs '^[[:space:]]*KASKAD_LANG=' "${GOINST_FS_ROOT:-}/etc/kaskad/config" && return 0
    if [ "${LANG_CODE:-ru}" = en ]; then printf 'en'; else printf 'ru'; fi
}

# Запуск установщика продукта. Ключ — только через окружение и только в
# те переменные, которые продукт читает сам.
run_product_installer() {
    local id="$1" work entry rc key="" repo ref src local_src
    # ГРАБЛИ: `local src="GOINST_SRC_$1" local_src="${!src:-}"` одной строкой
    # НЕ работает. bash раскрывает все правые части ДО присваиваний, поэтому
    # на момент `${!src}` переменная `src` ещё пуста — выходит «invalid
    # indirect expansion», а под `set -u` это обрывает весь скрипт. Ломалась
    # при этом ЛЮБАЯ установка: строка стоит первой в функции. Ни один тест
    # этого не ловил, потому что запуск чужого установщика они не трогают.
    # Присваивать раздельно.
    src="GOINST_SRC_$1"
    local_src="${!src:-}"
    osup_busy_refuse && return 1
    # Ленивый pro у goAmnezia pro запускается флагом, без меню продукта:
    # `install.sh --lazy [--domain=…] [--keys=N]` (его docs/MODES_047.md, п. 7),
    # bootstrap передаёт аргументы install.sh как есть. Домен без
    # GOINST_LAZY_DOMAIN продукт спросит сам, со своими подсказками.
    local -a amz=()
    if [ "$id" = goamnezia ] && [ "${MODE:-}" = lazy ]; then
        amz=(--lazy)
        [ -n "${GOINST_LAZY_DOMAIN:-}" ] && amz+=("--domain=${GOINST_LAZY_DOMAIN}")
        [ -n "${GOINST_LAZY_KEYS:-}" ] && amz+=("--keys=${GOINST_LAZY_KEYS}")
    fi
    repo=$(prod_repo "$id"); ref="${REF:-$(prod_ref "$id")}"; entry=$(prod_entry "$id")
    work="${GOINST_DIR}/${id}"
    # Сообщение от mkdir вылезало сырым посреди разговора с человеком.
    # Своё — называет и каталог, и причину.
    if ! mkdir -p "$work" 2>/dev/null; then
        err "$(bi "Не удалось создать ${work} — нужны права root." "Could not create ${work} — root is required.")"
        return 1
    fi
    chmod 700 "$GOINST_DIR" 2>/dev/null || true

    if [ "$id" = "gowarp" ]; then
        # Лицензионный ключ goWARP передаётся первым аргументом warp.sh.
        key="${GOWARP_KEY:-}"
        if [ -z "$key" ] && ! prod_installed gowarp; then
            read_line key "  $(bi "Лицензионный ключ goWARP pro (из группы)" "goWARP pro license key (from the group)"): " || return 1
        fi
    fi

    if [ -n "$local_src" ]; then
        say "$(bi "Локальный источник: ${local_src}" "Local source: ${local_src}")"
        case "$id" in
            govless)    [ -f "$local_src/govless.sh" ] || { err "$(bi "Нет govless.sh в ${local_src}" "No govless.sh in ${local_src}")"; return 1; }
                        ( cd "$local_src" && GH_TOKEN="$TOKEN" bash ./govless.sh ); rc=$? ;;
            gotelegram) [ -f "$local_src/install.sh" ] || { err "$(bi "Нет install.sh в ${local_src}" "No install.sh in ${local_src}")"; return 1; }
                        ( cd "$local_src" && GOTELEGRAM_PAT="$TOKEN" bash ./install.sh ); rc=$? ;;
            godns)      [ -f "$local_src/install.sh" ] || { err "$(bi "Нет install.sh в ${local_src}" "No install.sh in ${local_src}")"; return 1; }
                        GODNS_LOCAL_SRC="$local_src" bash "$local_src/install.sh"; rc=$? ;;
            gokaskad)   cp -f "$local_src/install.sh" "$work/install.sh" || return 1
                        chmod 700 "$work/install.sh"; ( cd "$work" && KASKAD_BRANCH="${REF:-$(prod_ref "$id")}" KASKAD_LANG="$(gokaskad_lang_env)" ./install.sh ); rc=$? ;;
            gowarp)     cp -f "$local_src/warp.sh" "$work/warp.sh" || return 1
                        chmod 700 "$work/warp.sh"; ( cd "$work" && bash ./warp.sh "$key" ); rc=$? ;;
            # Как у goDNS pro — через загрузчик продукта: install.sh прямо из
            # дерева искал lib/upstream/images.json в /opt/goamnezia/lib, и
            # профили не вставали. GOAMNEZIA_LOCAL_TREE — тот же путь, что у
            # настоящей установки, без сети и ключа (bootstrap.sh продукта).
            goamnezia)  [ -f "$local_src/bootstrap.sh" ] || { err "$(bi "Нет bootstrap.sh в ${local_src}" "No bootstrap.sh in ${local_src}")"; return 1; }
                        GOAMNEZIA_LOCAL_TREE="$local_src" GOAMNEZIA_BRANCH="${REF:-$(prod_ref "$id")}" bash "$local_src/bootstrap.sh" ${amz[@]+"${amz[@]}"}; rc=$? ;;
        esac
        return "$rc"
    fi

    ensure_token || return 1
    say "$(bi "Скачиваю ${entry} из ${repo}@${ref}…" "Downloading ${entry} from ${repo}@${ref}…")"
    fetch_raw "$repo" "$ref" "$entry" "$work/$entry" || return 1
    chmod 700 "$work/$entry"
    echo ""
    hr
    echo -e "  ${BOLD}$(bi "Передаю управление установщику" "Handing over to the installer") $(prod_name "$id")${NC}"
    hr
    echo ""
    case "$id" in
        # bootstrap goVLESS клонирует репозиторий в /opt/govless-installer; ключ читает из GH_TOKEN.
        # Смену ветки у установленного загрузчик goVLESS делает сам с 1.3.7;
        # итог сверяет installer_postcheck.
        govless)    ( cd "$work" && GH_TOKEN="$TOKEN" GOVLESS_BRANCH="$ref" bash ./bootstrap.sh ); rc=$? ;;
        # bootstrap goTelegram качает файлы по SHA ветки; ключ — GOTELEGRAM_PAT.
        gotelegram) ( cd "$work" && GOTELEGRAM_PAT="$TOKEN" GOTELEGRAM_BRANCH="$ref" bash ./bootstrap.sh ); rc=$? ;;
        # install.sh goDNS тянет tarball через api.github.com; ключ — GH_TOKEN.
        godns)      ( cd "$work" && GH_TOKEN="$TOKEN" GODNS_REF="$ref" bash ./install.sh ); rc=$? ;;
        # Kaskad и goWARP — сами себе программа: копируют $0 в /usr/local/bin,
        # поэтому запускать их надо ИЗ ФАЙЛА, а не из подстановки процесса.
        # 3.x записывает KASKAD_BRANCH ветвью обновлений; 2.x ни её, ни KASKAD_LANG не читает.
        gokaskad)   ( cd "$work" && KASKAD_BRANCH="$ref" KASKAD_LANG="$(gokaskad_lang_env)" ./install.sh ); rc=$? ;;
        gowarp)     ( cd "$work" && bash ./warp.sh "$key" ); rc=$? ;;
        # bootstrap goAmnezia качает срез ветки по SHA; ключ — GOAMNEZIA_PAT.
        # ${amz[@]+…}: пустой массив под set -u в bash до 4.4 — «unbound variable».
        goamnezia)  ( cd "$work" && GOAMNEZIA_PAT="$TOKEN" GOAMNEZIA_BRANCH="$ref" bash ./bootstrap.sh ${amz[@]+"${amz[@]}"} ); rc=$? ;;
    esac
    return "$rc"
}

# ── опрос версий на GitHub ──────────────────────────────────────────────
# Что доступно в ветке, видно только из репозитория, а репозитории закрытые:
# без ключа опрос не делается вовсе. Молча висеть на сети меню не должно,
# поэтому: все запросы разом в фоне, жёсткий тайм-аут на каждый, ответ
# кладётся в кеш со штампом времени. Промах кеша тоже кладётся — иначе
# недоступная ветка опрашивалась бы на каждой перерисовке экрана.
VER_CACHE="${GOINST_VER_CACHE:-${GOINST_DIR}/versions}"
VER_TTL="${GOINST_VER_TTL:-60}"
VER_NET_TRIED="no"   # опрос делали хотя бы раз
VER_NET_OK="no"      # хоть один ответ получен

# ── GitHub: условные запросы и общий лимит ──────────────────────────────
# Ключ клуба один на всех, а лимит GitHub — 5000 запросов в час на
# владельца ключа, то есть на все серверы клуба разом. Опрос версий стоил
# около двадцати запросов, открытое меню повторяло его раз в три минуты, и
# полтора десятка открытых меню выбирали лимит за час. Два приёма:
#  - условный запрос: ETag прошлого ответа уходит в If-None-Match, и ответ
#    304 «не изменилось» GitHub в лимит не засчитывает (проверено на ключе
#    клуба: x-ratelimit-used на 304 не растёт);
#  - исчерпанный лимит — отдельное состояние, а не «ключ плохой». GitHub
#    отвечает 403 и на него, и на закрытый репозиторий; различает их только
#    заголовок. До часа сброса сеть не трогаем, прежние сведения держим.
GH_HTTP_CACHE="${VER_CACHE}/http"
GH_LIMIT_FILE="${VER_CACHE}/@ratelimit"

_hhmm() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || printf '?'; }

# gh_limited → 0, пока действует отметка об исчерпанном лимите; печатает
# время сброса «ЧЧ:ММ». Прошедшая отметка удаляется.
gh_limited() {
    local until="" now
    [ -r "$GH_LIMIT_FILE" ] || return 1
    read -r until < "$GH_LIMIT_FILE" 2>/dev/null || true
    case "$until" in ''|*[!0-9]*) return 1 ;; esac
    now=$(_ver_now)
    if [ "$now" -ge "$until" ]; then rm -f "$GH_LIMIT_FILE" 2>/dev/null; return 1; fi
    _hhmm "$until"
    return 0
}
# «к 15:00» или «к началу следующего часа», когда отметки нет.
gh_reset_text() {
    local t
    if t=$(gh_limited); then printf '%s' "$t"; else bi "началу следующего часа" "the top of the hour"; fi
}

# gh_limit_mark <заголовки> → 0, если отказ — исчерпанный лимит, и отметка
# записана. Признаки: x-ratelimit-remaining: 0 (основной лимит) или
# retry-after (вторичный, за частоту).
gh_limit_mark() {
    local h rem reset retry now until
    [ -r "$1" ] || return 1
    h=$(tr -d '\r' < "$1" | tr '[:upper:]' '[:lower:]')
    rem=$(sed -n -E 's/^x-ratelimit-remaining:[[:space:]]*([0-9]+).*/\1/p' <<<"$h" | tail -1)
    reset=$(sed -n -E 's/^x-ratelimit-reset:[[:space:]]*([0-9]+).*/\1/p' <<<"$h" | tail -1)
    retry=$(sed -n -E 's/^retry-after:[[:space:]]*([0-9]+).*/\1/p' <<<"$h" | tail -1)
    now=$(_ver_now)
    if [ -n "$retry" ]; then until=$(( now + retry ))
    elif [ "$rem" = "0" ]; then until="${reset:-$(( now + 3600 ))}"
    else return 1; fi
    mkdir -p "$VER_CACHE" 2>/dev/null || true
    printf '%s\n' "$until" > "$GH_LIMIT_FILE" 2>/dev/null || true
    return 0
}

_gh_etag_save() {  # _gh_etag_save <заголовки> <файл метки>
    tr -d '\r' < "$1" | sed -n -E 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*(.+)$/\1/p' | head -1 > "$2" 2>/dev/null || true
}

# gh_get <url> <cfg> <куда> [Accept] → 0 и тело в файле; 2 — лимит
# исчерпан; 1 — нет ответа или нет доступа. Тело прошлого ответа и его ETag
# лежат в кеше: на 304 отдаётся тело оттуда.
gh_get() {
    local url="$1" cfg="$2" out="$3" accept="${4:-}" key body etag hdr code
    local -a extra=()
    gh_limited >/dev/null && return 2
    key="${url#https://api.github.com/}"; key="${key//[^A-Za-z0-9._-]/_}"
    body="$GH_HTTP_CACHE/$key.body"; etag="$GH_HTTP_CACHE/$key.etag"
    mkdir -p "$GH_HTTP_CACHE" 2>/dev/null && chmod 700 "$GH_HTTP_CACHE" 2>/dev/null
    [ -n "$accept" ] && extra+=(-H "Accept: $accept")
    if [ -s "$body" ] && [ -s "$etag" ]; then extra+=(-H "If-None-Match: $(head -1 "$etag")"); fi
    hdr=$(mktemp "${TMPDIR:-/tmp}/goinst-hdr.XXXXXX") || return 1
    rm -f "$out"
    # ${extra[@]+…}: пустой массив под set -u в bash до 4.4 — «unbound variable».
    code=$(gh_curl --config "$cfg" --max-time "${GOINST_VER_TIMEOUT:-$GH_MT}" ${extra[@]+"${extra[@]}"} \
           -D "$hdr" -o "$out" -w '%{http_code}' "$url") || true
    GH_GET_CODE="$code"   # код ответа — тем, кому мало rc (401 у self_ref_find)
    case "$code" in
        200)
            cp -f "$out" "$body" 2>/dev/null || true
            _gh_etag_save "$hdr" "$etag"
            rm -f "$hdr"; return 0 ;;
        304)
            # На 304 тела нет, и curl файла не создаёт.
            rm -f "$hdr"
            cp -f "$body" "$out" 2>/dev/null && return 0
            return 1 ;;
        403|429)
            if gh_limit_mark "$hdr"; then rm -f "$hdr" "$out"; return 2; fi ;;
    esac
    rm -f "$hdr" "$out"
    return 1
}

_ver_now() { printf '%s' "$(date +%s)"; }

# Файл кеша: одна строка "<штамп> <версия>"; пустая версия — «спрашивали,
# там нет».
# ГРАБЛИ: имя ветки бывает со слэшем (`backup/pre-v2.5`), и оно уезжало в
# путь файла как подкаталог — запись падала с «No such file or directory».
# Заменяем всё, что не буква и не цифра.
_ver_cache_file() {
    local id="${1//[^A-Za-z0-9@_.-]/_}" ref="${2//[^A-Za-z0-9@_.-]/_}"
    printf '%s/%s.%s' "$VER_CACHE" "$id" "$ref"
}

ver_cache_read() {   # ver_cache_read <id> <ref> → версия; rc 1 — нет свежего
    local f stamp rest now
    f=$(_ver_cache_file "$1" "$2")
    [ -r "$f" ] || return 1
    read -r stamp rest < "$f" 2>/dev/null || return 1
    case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
    now=$(_ver_now)
    [ $(( now - stamp )) -lt "$VER_TTL" ] || return 1
    printf '%s' "$rest"
    return 0
}

# ver_cache_get — то же, но без срока годности: для ПОКАЗА. Срок в минуту
# решает, пора ли спросить GitHub заново, а не то, можно ли показать
# последнее известное. Иначе через минуту после опроса колонка версий
# пустела бы до следующего такта, хотя ответ лежит на диске.
ver_cache_get() {
    local f stamp rest
    f=$(_ver_cache_file "$1" "$2")
    [ -r "$f" ] || return 1
    read -r stamp rest < "$f" 2>/dev/null || return 1
    case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$rest"
    return 0
}

ver_cache_write() { local f; f=$(_ver_cache_file "$1" "$2"); printf '%s %s\n' "$(_ver_now)" "${3:-}" > "$f" 2>/dev/null || true; }
# Прежнее значение с новым штампом: сведения не терялись, а переспрос ждал TTL.
ver_cache_touch() { local v; v=$(ver_cache_get "$1" "$2") || v=""; ver_cache_write "$1" "$2" "$v"; }

# Один запрос: сырой файл из ветки → номер версии. Ошибки молчат: отсутствие
# ветки и отсутствие сети для этого экрана — не событие.
_ver_fetch_one() {
    local id="$1" ref="$2" cfg="$3" repo spec var path url tmp v=""
    repo=$(prod_repo "$id")
    spec=$(prod_ver_spec "$id") || spec=""
    var="${spec#*|}"; [ "$var" = "$spec" ] && var=""
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-ver.XXXXXX") || return 0
    local at="$ref" sha="" shaf s0="" v0=""
    sha=$(ref_sha "$repo" "$ref" "$cfg") && at="$sha"
    # Версия на коммите не меняется никогда: тот же хеш — тот же ответ, и
    # файл из ветки качать незачем.
    shaf="$(_ver_cache_file "$id" "$ref").sha"
    if [ -n "$sha" ] && [ -r "$shaf" ]; then
        read -r s0 v0 < "$shaf" 2>/dev/null || s0=""
        if [ "$s0" = "$sha" ] && [ -n "$v0" ]; then rm -f "$tmp"; ver_cache_write "$id" "$ref" "$v0"; return 0; fi
    fi
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        url="https://raw.githubusercontent.com/${repo}/${at}/${path}"
        gh_curl --config "$cfg" --max-time "${GOINST_VER_TIMEOUT:-$GH_MT}" -o "$tmp" "$url" >/dev/null 2>&1 || continue
        # Сначала ищем названную переменную, потом любую «…VERSION=».
        # Второе спасает, когда продукт переименовал её у себя.
        if [ -n "$var" ] && v=$(ver_extract "$tmp" "$var"); then break; fi
        if v=$(ver_extract_any "$tmp"); then break; fi
        v=""
    done < <(prod_ver_paths "$id")
    rm -f "$tmp"
    ver_cache_write "$id" "$ref" "$v"
    if [ -n "$sha" ] && [ -n "$v" ]; then printf '%s %s\n' "$sha" "$v" > "$shaf" 2>/dev/null || true; fi
    return 0
}

# Ветка, С КОТОРОЙ продукт стоит. goTelegram и goAmnezia записывают её при
# установке, goKaskad pro 3 — в своих настройках, goVLESS — HEAD клона; у
# остальных спросить неоткуда. Нужна как умолчание при
# обновлении: человек, сидящий на стабильной ветке, не должен переезжать на
# отладочную оттого, что промахнулся по Enter.
prod_installed_ref() {
    local r="${GOINST_FS_ROOT:-}" f v
    # goVLESS не пишет .install-source: его код лежит git-клоном, и ветка —
    # это просто HEAD клона.
    if [ "$1" = "govless" ]; then
        # Клон бесплатного Lite — не ветка pro. У Lite своя dev, и её HEAD,
        # взятый умолчанием, увёл бы человека на отладочную ветку pro.
        prod_free_lite govless && return 1
        f="$r/opt/govless-installer"
        [ -d "$f/.git" ] || return 1
        v=$(git -C "$f" rev-parse --abbrev-ref HEAD 2>/dev/null) || v=""
        case "$v" in ''|HEAD) return 1 ;; esac
        printf '%s' "$v"
        return 0
    fi
    # goKaskad pro 3 пишет ветку обновлений в свои настройки (KASKAD_BRANCH).
    # 2.x веток не знает: строка, оставшаяся от 3.x после возврата на 2.x,
    # ветку не означает. 3.x живёт в dev (на main — 2.x), а сам себе пишет
    # и k3, и test (цепочка обновления main → test → k3), или ничего, если
    # ставили без переменной. Ветка не из списка — значит dev: иначе
    # умолчанием стала бы main, и Enter откатил бы 3.x на 2.x. Сверке после
    # установки (второй аргумент raw) нужна записанная ветка как есть: k3
    # после оборванного установщика — не «стоит с dev».
    if [ "$1" = "gokaskad" ]; then
        local rf
        v=$(prod_version gokaskad 2>/dev/null) || v=""
        case "$v" in [3-9].*|[1-9][0-9]*.*) ;; *) return 1 ;; esac
        f="$r/etc/kaskad/config"
        v=$(sed -n -E 's/^[[:space:]]*KASKAD_BRANCH=["'"'"']?([A-Za-z0-9._/-]+)["'"'"']?[[:space:]]*$/\1/p' "$f" 2>/dev/null | tail -1) || v=""
        if [ "${2:-}" = raw ]; then [ -n "$v" ] || return 1; printf '%s' "$v"; return 0; fi
        for rf in $(prod_refs gokaskad); do [ "$rf" = "$v" ] && { printf '%s' "$v"; return 0; }; done
        for rf in $(prod_refs gokaskad); do [ "$rf" = dev ] && { printf 'dev'; return 0; }; done
        return 1
    fi
    case "$1" in
        gotelegram) f="$r/opt/gotelegram/.install-source" ;;
        goamnezia)  f="$r/opt/goamnezia/.install-source" ;;
        *) return 1 ;;
    esac
    [ -r "$f" ] || return 1
    v=$(sed -n -E 's/^[[:space:]]*branch=(.+)$/\1/p' "$f" 2>/dev/null | head -1) || v=""
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Чем ветка отличается для того, кто выбирает. Имена веток говорят это
# только тем, кто их уже знает.
ref_kind() {
    case "$1" in
        main|master) bi "стабильная" "stable" ;;
        dev)         bi "экспериментальная" "experimental" ;;
        rc*)         bi "предрелизная" "release candidate" ;;
        *)           printf '' ;;
    esac
}

# Опрос «удался» не тогда, когда curl вернул 0, а тогда, когда на руках есть
# хоть один номер версии. Иначе колонка рисуется пустой на всю высоту.
_ver_mark_ok() {
    local id
    VER_NET_OK="no"
    for id in "$@"; do
        if prod_best_remote "$id" >/dev/null 2>&1; then VER_NET_OK="yes"; return 0; fi
    done
    return 0
}

# versions_fetch [id…] — опросить всё, чего нет в свежем кеше. Запросы идут
# параллельно: последовательно шесть продуктов на двух ветках — это дюжина
# рукопожатий TLS подряд, то есть заметное ожидание на пустом месте.
versions_fetch() {
    local ids=("${@:-${PRODUCTS[@]}}") id ref cfg need=0
    # Не спрашивать — не значит не знать: спрошенное раньше лежит в кеше, и
    # прятать его из-за отсутствия сети значило бы терять готовый ответ.
    [ -z "${GOINST_NO_NET:-}" ] || { _ver_mark_ok "${ids[@]}"; return 0; }
    [ -n "$TOKEN" ] || { _ver_mark_ok "${ids[@]}"; return 0; }
    command -v curl >/dev/null 2>&1 || { _ver_mark_ok "${ids[@]}"; return 0; }
    # Лимит исчерпан — до сброса сеть не трогаем: прежние сведения из кеша
    # остаются на экране, а новый вопрос получил бы тот же отказ.
    if gh_limited >/dev/null; then VER_NET_TRIED="yes"; _ver_mark_ok "${ids[@]}"; return 0; fi
    mkdir -p "$VER_CACHE" 2>/dev/null || return 0
    chmod 700 "$VER_CACHE" 2>/dev/null || true
    for id in "${ids[@]}"; do
        ver_cache_read "$id" "@refs" >/dev/null || need=1
        for ref in $(prod_refs_probe "$id"); do
            ver_cache_read "$id" "$ref" >/dev/null || need=1
        done
    done
    [ "$need" -eq 1 ] || { VER_NET_TRIED="yes"; _ver_mark_ok "${ids[@]}"; return 0; }
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-vercurl.XXXXXX") || return 0
    chmod 600 "$cfg"
    {
        echo 'silent'; echo 'location'; echo 'fail'
        gh_cfg_net
        printf 'header = "Authorization: token %s"\n' "$TOKEN"
    } > "$cfg"
    say "$(bi "Спрашиваю GitHub про ветки и версии…" "Asking GitHub about branches and versions…")"
    VER_NET_TRIED="yes"
    # Свои журнал повторов и метка «сети нет» на этот заход — если их не
    # задал вызывающий. После — одна строка о том, что было и почему.
    local vrun="" vdir=""
    if [ -z "$GH_DOWN_FILE" ] && vdir=$(mktemp -d "${TMPDIR:-/tmp}/goinst-vrun.XXXXXX"); then
        GH_DOWN_FILE="$vdir/down"; GH_RETRY_LOG="$vdir/retries"; vrun=1
    fi
    # Ветки — первым заходом: какие версии спрашивать, известно только
    # после того, как известно, какие ветки вообще есть.
    local -a vp=()
    for id in "${ids[@]}"; do
        ver_cache_read "$id" "@refs" >/dev/null && continue
        refs_fetch_one "$id" "$cfg" &
        vp+=("$!")
    done
    if [ -n "$vrun" ]; then gh_wait_report ${vp[@]+"${vp[@]}"}; else wait; fi
    vp=()
    for id in "${ids[@]}"; do
        for ref in $(prod_refs_probe "$id"); do
            ver_cache_read "$id" "$ref" >/dev/null && continue
            _ver_fetch_one "$id" "$ref" "$cfg" &
            vp+=("$!")
        done
    done
    # Ключ лежит в файле, пока идут запросы: удалять его можно только
    # после того, как все дочерние curl закончили им пользоваться.
    if [ -n "$vrun" ]; then gh_wait_report ${vp[@]+"${vp[@]}"}; else wait; fi
    rm -f "$cfg"
    if [ -n "$vrun" ] && gh_can_say; then
        if [ -s "$GH_DOWN_FILE" ]; then
            warn "$(bi "GitHub не отвечает: $(gh_net_reason "$(head -1 "$GH_DOWN_FILE")"). Показываю прежние сведения о версиях." "GitHub does not answer: $(gh_net_reason "$(head -1 "$GH_DOWN_FILE")"). Showing the previous version data.")"
        elif [ -s "$GH_RETRY_LOG" ]; then
            say "$(bi "Связь с GitHub неустойчива: сведения получены после повторов ($(wc -l < "$GH_RETRY_LOG" | tr -d ' ')). Причина сбоев: $(gh_net_reason "$(awk 'END{print $1}' "$GH_RETRY_LOG")")." "The GitHub connection is unstable: the data came after retries ($(wc -l < "$GH_RETRY_LOG" | tr -d ' ')). Cause of the failures: $(gh_net_reason "$(awk 'END{print $1}' "$GH_RETRY_LOG")").")"
        fi
    fi
    [ -n "$vrun" ] && { rm -rf "$vdir"; GH_DOWN_FILE=""; GH_RETRY_LOG=""; }
    _ver_mark_ok "${ids[@]}"
    return 0
}

# ver_fill_refs <id> — добрать версии тех веток, которые ещё не спрашивали.
# Нужна экрану выбора ветки: там показываются ВСЕ ветки, а при запуске
# опрашиваются только первые REFS_MAX — остальные без этого были бы вечно
# «не спрошены», и выбирать пришлось бы вслепую.
ver_fill_refs() {
    local id="$1" ref cfg need=0
    [ -z "${GOINST_NO_NET:-}" ] || return 0
    [ -n "$TOKEN" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    mkdir -p "$VER_CACHE" 2>/dev/null || return 0
    for ref in $(prod_refs "$id"); do
        ver_cache_read "$id" "$ref" >/dev/null || need=1
    done
    [ "$need" -eq 1 ] || return 0
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-vercurl.XXXXXX") || return 0
    chmod 600 "$cfg"
    {
        echo 'silent'; echo 'location'; echo 'fail'
        gh_cfg_net
        printf 'header = "Authorization: token %s"\n' "$TOKEN"
    } > "$cfg"
    local fdir="" fown=""
    if [ -z "$GH_DOWN_FILE" ] && fdir=$(mktemp -d "${TMPDIR:-/tmp}/goinst-frun.XXXXXX"); then GH_DOWN_FILE="$fdir/down"; fown=1; fi
    for ref in $(prod_refs "$id"); do
        ver_cache_read "$id" "$ref" >/dev/null && continue
        _ver_fetch_one "$id" "$ref" "$cfg" &
    done
    wait
    rm -f "$cfg"
    [ -n "$fown" ] && { rm -rf "$fdir"; GH_DOWN_FILE=""; }
    return 0
}

# Забыть опрошенное: пункт «обновить сведения» обязан спрашивать заново, а
# не показывать то же самое из кеша.
versions_forget() { rm -f "${VER_CACHE}"/*.* 2>/dev/null || true; VER_NET_TRIED="no"; VER_NET_OK="no"; }

# ver_newer <a> <b> — rc 0, если b строго новее a. `sort -V` не путается на
# 0.9.0 против 0.10.0, чего не умеет ни строковое сравнение, ни разбор по
# точкам «на глаз».
ver_newer() {
    local a="$1" b="$2" top
    [ -n "$b" ] || return 1
    [ -n "$a" ] || return 0
    [ "$a" = "$b" ] && return 1
    top=$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | tail -1) || return 1
    [ "$top" = "$b" ]
}

# Лучшее, что нашли по веткам: печатает "ветка версия". При равных версиях
# на разных ветках побеждает первая в списке — он идёт от стабильной к
# отладочной.
prod_best_remote() {
    local id="$1" ref v best_v="" best_ref=""
    for ref in $(prod_refs "$id"); do
        v=$(ver_cache_get "$id" "$ref") || continue
        [ -n "$v" ] || continue
        if [ -z "$best_v" ] || ver_newer "$best_v" "$v"; then best_v="$v"; best_ref="$ref"; fi
    done
    [ -n "$best_v" ] || return 1
    printf '%s %s' "$best_ref" "$best_v"
}

# ── своя версия и обновление самого себя ────────────────────────────────
# goInstaller живёт в таком же закрытом репозитории, с теми же ветками и тем
# же ключом, что и продукты. Значит и версию свою он обязан узнавать так же
# — из ветки, а не из того, что записано в нём самом.
SELF_ID="@self"

self_refs() {
    local cached saved
    if [ -n "${GOINST_SELF_REFS:-}" ]; then printf '%s' "$GOINST_SELF_REFS"; return 0; fi
    cached=$(ver_cache_get "$SELF_ID" "@refs") && [ -n "$cached" ] || cached="$GOINST_SELF_REF"
    # Ветка, из которой ставился goinstall (self_ref_remember), — к main и dev.
    if saved=$(self_ref_saved) && ! grep -qxF -- "$saved" <<<"$cached"; then cached="${cached}"$'\n'"${saved}"; fi
    printf '%s' "$cached"
}

# ── своя ветка ──────────────────────────────────────────────────────────
# Из `bash <(curl …/test-shield/go-installer.sh)` скрипт не знает, из какой
# ветки его скачали, а self_install ставил в goinstall GOINST_SELF_REF
# (main) — другую версию, и защите нечего было дать таймеру (живой сервер,
# 03.11.2026). Теперь ветку этой версии ищут (self_ref_find), а найденную
# запоминают: self_refs предлагает её обновлениям наравне с main и dev.
SELF_REF_FILE="${GOINST_SELF_REF_FILE:-${GOINST_DIR}/.self-ref}"
SELF_REF_HIT=""                                  # ветка этой версии, найденная в этом запуске
SELF_FIND_MAX="${GOINST_SELF_FIND_MAX:-30}"      # веток в поиске, не больше
SELF_NONE_TTL="${GOINST_SELF_NONE_TTL:-10}"      # минут: «в ветке скрипта нет» не навсегда
SELF_REF_MANY=""                                 # ветки одной версии с разным содержимым

# Имя ветки идёт в URL, в имя файла и в совет человеку — только простые знаки.
_self_ref_ok() {
    case "$1" in ''|-*|/*|*/|*..*|*//*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
    [ "${#1}" -le 100 ]
}
self_ref_saved() {
    local r=""
    [ -r "$SELF_REF_FILE" ] || return 1
    IFS= read -r r < "$SELF_REF_FILE" 2>/dev/null || true
    _self_ref_ok "$r" || return 1
    printf '%s' "$r"
}
# main и dev опрашиваются и так: их не запоминаем, прежняя запись стирается.
self_ref_remember() {
    case "$1" in
        main|dev|"$GOINST_SELF_REF") rm -f "$SELF_REF_FILE" 2>/dev/null ;;
        *) _self_ref_ok "$1" || return 0
           mkdir -p "$(dirname "$SELF_REF_FILE")" 2>/dev/null
           printf '%s\n' "$1" > "$SELF_REF_FILE" 2>/dev/null ;;
    esac
    return 0
}
# main догнал ветку, из которой ставился goinstall (решение владельца 04.11:
# апрув → тест-ветка → main): версия main не ниже и стоящей, и лежащей в
# запомненной ветке — запись стирается, дальше обновления идут из main и dev,
# сервер не остаётся на тестовой ветке. Стоящая или ветка новее main — запись
# остаётся (REVIEW-8 №1: main принял 1.2.5, а в ветке уже 1.2.6). Версии
# ветки нет (сбой пробы пишет пустую) — запись тоже остаётся: сбой ветку не
# отменяет, а удалённую ветку забывает self_fetch_versions по списку веток.
_self_ref_caught() {
    local r mv iv sv
    r=$(self_ref_saved) || return 0
    mv=$(ver_cache_get "$SELF_ID" "$GOINST_SELF_REF") && [ -n "$mv" ] || return 0
    iv=$(ver_extract "$GOINST_BIN" "GOINST_VERSION") || return 0
    ver_newer "$mv" "$iv" && return 0
    sv=$(ver_cache_get "$SELF_ID" "$r") && [ -n "$sv" ] || return 0
    ver_newer "$mv" "$sv" && return 0
    rm -f "$SELF_REF_FILE" 2>/dev/null
    return 0
}

self_fetch_versions() {
    local cfg ref need=0
    [ -z "${GOINST_NO_NET:-}" ] || return 0
    [ -n "$TOKEN" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    gh_limited >/dev/null && return 0
    mkdir -p "$VER_CACHE" 2>/dev/null || return 0
    ver_cache_read "$SELF_ID" "@refs" >/dev/null || need=1
    for ref in $(self_refs); do ver_cache_read "$SELF_ID" "$ref" >/dev/null || need=1; done
    [ "$need" -eq 1 ] || { _self_ref_caught; return 0; }
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-self.XXXXXX") || return 0
    chmod 600 "$cfg"
    { echo 'silent'; echo 'location'; echo 'fail'; gh_cfg_net
      printf 'header = "Authorization: token %s"\n' "$TOKEN"; } > "$cfg"
    if ! ver_cache_read "$SELF_ID" "@refs" >/dev/null; then
        local names
        if [ -n "${GOINST_BRANCHES_FIXTURE:-}" ]; then
            names=$(sed -n -E "s#^${GOINST_SELF_REPO}=(.*)\$#\1#p" "$GOINST_BRANCHES_FIXTURE" 2>/dev/null | head -1 | tr ' ' '\n')
        else
            local tmpb rc=0
            names=""
            if tmpb=$(mktemp "${TMPDIR:-/tmp}/goinst-selfr.XXXXXX"); then
                gh_get "https://api.github.com/repos/${GOINST_SELF_REPO}/branches?per_page=100" "$cfg" "$tmpb" || rc=$?
                names=$(sed -n -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmpb" 2>/dev/null) || names=""
                rm -f "$tmpb"
            fi
            [ "$rc" -eq 2 ] && ver_cache_touch "$SELF_ID" "@refs"
        fi
        [ "${rc:-0}" -eq 2 ] || ver_cache_write "$SELF_ID" "@refs" "$(printf '%s\n' "$names" | refs_sort)"
        # Запомненной ветки в репозитории больше нет — и опрашивать нечего.
        local saved
        if [ -n "$names" ] && saved=$(self_ref_saved) && ! grep -qxF -- "$saved" <<<"$names"; then rm -f "$SELF_REF_FILE" 2>/dev/null; fi
    fi
    local tmp v at s shaf s0 v0
    for ref in $(self_refs); do
        ver_cache_read "$SELF_ID" "$ref" >/dev/null && continue
        (
            tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-selfv.XXXXXX") || exit 0
            v=""; at=""; s=""
            at="$ref"; s=$(ref_sha "$GOINST_SELF_REPO" "$ref" "$cfg") && at="$s"
            shaf="$(_ver_cache_file "$SELF_ID" "$ref").sha"; s0=""; v0=""
            if [ -n "$s" ] && [ -r "$shaf" ]; then read -r s0 v0 < "$shaf" 2>/dev/null || s0=""; fi
            if [ -n "$s" ] && [ "$s0" = "$s" ] && [ -n "$v0" ]; then
                v="$v0"
            elif gh_curl --config "$cfg" --max-time "${GOINST_VER_TIMEOUT:-$GH_MT}" -o "$tmp" \
                 "https://raw.githubusercontent.com/${GOINST_SELF_REPO}/${at}/go-installer.sh" >/dev/null 2>&1; then
                v=$(ver_extract "$tmp" "GOINST_VERSION") || v=""
                if [ -n "$s" ] && [ -n "$v" ]; then printf '%s %s\n' "$s" "$v" > "$shaf" 2>/dev/null || true; fi
            fi
            rm -f "$tmp"
            ver_cache_write "$SELF_ID" "$ref" "$v"
        ) &
    done
    wait
    rm -f "$cfg"
    _self_ref_caught
    return 0
}

# Лучшее, что лежит в ветках самого установщика: "ветка версия".
self_best() {
    local ref v best_v="" best_ref=""
    for ref in $(self_refs); do
        v=$(ver_cache_get "$SELF_ID" "$ref") || continue
        [ -n "$v" ] || continue
        if [ -z "$best_v" ] || ver_newer "$best_v" "$v"; then best_v="$v"; best_ref="$ref"; fi
    done
    [ -n "$best_v" ] || return 1
    printf '%s %s' "$best_ref" "$best_v"
}

# ── сводка версий для всего клуба ──────────────────────────────────────
# Таймер сводки при входе стоит на сотнях серверов клуба, и каждый опрашивал
# бы шесть репозиториев сам — два десятка запросов в полчаса с сервера на
# ОДНОМ ключе. Условные запросы (304) основной лимит не тратят, но у GitHub
# есть и вторичный — на частоту, — и его они не снимают. Поэтому сводку
# собирает GitHub Actions (.github/workflows/versions.yml): раз в час
# `go-installer.sh --digest` опрашивает всё тем же кодом, что и сервер, и
# кладёт versions.txt в ветку versions этого репозитория. Таймер берёт её
# одним условным запросом; открытое меню спрашивает само — там важна
# точность, а не цена.
#
# Формат — строки, чтобы читать без jq:
#   format=1
#   generated=<unix-время сборки>
#   <id> @refs <ветки через пробел>
#   <id> <ветка> <версия или -> <хеш коммита или ->
DIGEST_REF="${GOINST_DIGEST_REF:-versions}"
DIGEST_PATH="versions.txt"
# Actions публикует сводку при изменениях, а без них — если прошлой больше
# двух часов (запуски по расписанию на деле идут раз в 3–9 часов); старше
# 12 часов — сборка сломалась, и такой сводке верить нельзя.
DIGEST_MAX_AGE="${GOINST_DIGEST_MAX_AGE:-43200}"

# digest_build — собрать сводку (для Actions). Печатает её в stdout; rc 1,
# если хоть у одного продукта не видно веток: полсводки хуже старой, и
# Actions тогда не публикует ничего.
digest_build() {
    local id ref v sha rest refs bad=0
    if [ -z "${TOKEN:-}" ]; then err "$(bi "Нет ключа: сводку собрать нечем (GH_TOKEN)." "No key: nothing to build the digest with (GH_TOKEN).")"; return 1; fi
    VER_TTL=0
    versions_fetch >/dev/null
    self_fetch_versions
    printf 'format=1\ngenerated=%s\n' "$(_ver_now)"
    for id in "${PRODUCTS[@]}" "$SELF_ID"; do
        refs=$(ver_cache_get "$id" "@refs") || refs=""
        if [ -z "$refs" ]; then
            err "$(bi "${id}: веток не видно — у ключа нет доступа или GitHub не ответил." "${id}: no branches visible — the key has no access or GitHub did not answer.")"
            bad=1; continue
        fi
        printf '%s @refs %s\n' "$id" "$refs"
        for ref in $refs; do
            v=$(ver_cache_get "$id" "$ref") || v=""
            sha=""; read -r sha rest < "$(_ver_cache_file "$id" "$ref").sha" 2>/dev/null || sha=""
            printf '%s %s %s %s\n' "$id" "$ref" "${v:--}" "${sha:--}"
        done
    done
    [ "$bad" -eq 0 ]
}

# digest_apply <файл> — разложить сводку по кешу версий, как будто сервер
# спросил сам. rc 1 — формат чужой, сводка старая или неполная: тогда в кеш
# не пишется ничего. Каждое поле сверяется со строгим образцом: значения
# попадают на экран и в имена файлов кеша.
digest_apply() {
    local f="$1" l fmt="" gen="" now id ref rest v sha seen=" "
    local -a rows=()
    [ -r "$f" ] || return 1
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            format=*)    fmt="${l#format=}" ;;
            generated=*) gen="${l#generated=}" ;;
            '') ;;
            *) rows+=("$l") ;;
        esac
    done < "$f"
    [ "$fmt" = 1 ] || return 1
    case "$gen" in ''|*[!0-9]*) return 1 ;; esac
    now=$(_ver_now)
    [ $(( now - gen )) -lt "$DIGEST_MAX_AGE" ] || return 1
    # Сначала проверить всё, потом писать: полсводки в кеше хуже старого кеша.
    # Незнакомый продукт пропускаем, а не отвергаем сводку: её собирает
    # goInstaller из main, и новый продукт появится в ней раньше, чем
    # обновятся серверы, — иначе все они разом ушли бы спрашивать сами.
    local -a mine=()
    for l in ${rows[@]+"${rows[@]}"}; do
        read -r id ref rest <<<"$l"
        case " ${PRODUCTS[*]} $SELF_ID " in *" $id "*) mine+=("$l") ;; *) continue ;; esac
        if [ "$ref" = "@refs" ]; then
            [[ "$rest" =~ ^[A-Za-z0-9._-]+(\ [A-Za-z0-9._-]+)*$ ]] || return 1
            seen+="$id "
        else
            [[ "$ref" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
            read -r v sha <<<"$rest"
            [[ "$v" =~ ^(-|[0-9][A-Za-z0-9._+-]*)$ ]] || return 1
            [[ "$sha" =~ ^(-|[0-9a-f]{40})$ ]] || return 1
        fi
    done
    for id in "${PRODUCTS[@]}" "$SELF_ID"; do
        case "$seen" in *" $id "*) ;; *) return 1 ;; esac
    done
    mkdir -p "$VER_CACHE" 2>/dev/null || return 1
    for l in "${mine[@]}"; do
        read -r id ref rest <<<"$l"
        if [ "$ref" = "@refs" ]; then ver_cache_write "$id" "@refs" "$rest"; continue; fi
        read -r v sha <<<"$rest"
        [ "$v" = - ] && v=""
        ver_cache_write "$id" "$ref" "$v"
        # Хеш с версией — тот же кеш, что у прямого опроса: следующий прямой
        # вопрос по этому коммиту файл из ветки уже не качает.
        if [ "$sha" != - ] && [ -n "$v" ]; then printf '%s %s\n' "$sha" "$v" > "$(_ver_cache_file "$id" "$ref").sha" 2>/dev/null || true; fi
    done
    return 0
}

# digest_fetch → 0 — кеш версий обновлён из сводки; 2 — лимит исчерпан;
# 1 — сводки нет или ей нельзя верить (зовущий спрашивает сам). Запрос
# условный: пока сводка та же, GitHub отвечает 304 и в лимит его не пишет.
digest_fetch() {
    local cfg out rc=0
    [ -z "${GOINST_NO_NET:-}" ] || return 1
    [ -n "${TOKEN:-}" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$VER_CACHE" 2>/dev/null || return 1
    chmod 700 "$VER_CACHE" 2>/dev/null || true
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-dg.XXXXXX") || return 1
    chmod 600 "$cfg"
    { echo 'silent'; echo 'location'; gh_cfg_net
      printf 'header = "Authorization: token %s"\n' "$TOKEN"; } > "$cfg"
    out=$(mktemp "${TMPDIR:-/tmp}/goinst-dgo.XXXXXX") || { rm -f "$cfg"; return 1; }
    gh_get "https://api.github.com/repos/${GOINST_SELF_REPO}/contents/${DIGEST_PATH}?ref=${DIGEST_REF}" \
        "$cfg" "$out" "application/vnd.github.raw" || rc=$?
    rm -f "$cfg"
    if [ "$rc" -eq 0 ] && ! digest_apply "$out"; then rc=1; fi
    rm -f "$out"
    return "$rc"
}

# Подменяем себя атомарно: скачали, проверили, положили рядом, переставили.
# Обрыв посреди copy оставил бы оператора без работающей команды.
self_update() {
    local ref="${1:-}" rv v tmp dest="$GOINST_BIN"
    osup_busy_refuse && return 1
    ensure_token || return 1
    self_fetch_versions
    if [ -z "$ref" ]; then
        if rv=$(self_best); then ref="${rv%% *}"; else ref="$GOINST_SELF_REF"; fi
    fi
    v=$(ver_cache_get "$SELF_ID" "$ref") || v=""
    say "$(bi "Обновляю goInstaller из ветки" "Updating goInstaller from branch") ${ref}${v:+ (${v})}…"
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-new.XXXXXX") || return 1
    if ! fetch_raw "$GOINST_SELF_REPO" "$ref" "go-installer.sh" "$tmp"; then rm -f "$tmp"; return 1; fi
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "$(bi "Скачанный файл не разбирается как скрипт — обновление отменено." "The downloaded file does not parse as a script — the update is cancelled.")"
        return 1
    fi
    _self_put "$tmp" || { rm -f "$tmp"; err "$(bi "Не удалось записать или заменить ${dest}." "Could not write or replace ${dest}.")"; return 1; }
    rm -f "$tmp"
    self_ref_remember "$ref"
    ok "$(bi "Обновлено. Запустите goinstall заново." "Updated. Start goinstall again.")"
    shield_self_update_note "$dest"
    return 0
}

# ── самоустановка ───────────────────────────────────────────────────────
# «имя хеш» веток из ответа GitHub на список веток (с отступами или в одну
# строку): за "name" ветки первым идёт "sha" её головы.
_self_branch_pairs() {
    grep -oE '"(name|sha)"[[:space:]]*:[[:space:]]*"[^"]*"' |
        sed -E 's/^"(name|sha)"[[:space:]]*:[[:space:]]*"(.*)"$/\1 \2/' |
        awk '$1 == "name" { n = $2; next } $1 == "sha" && n != "" { print n, $2; n = "" }'
}

# _self_probe <ветка> <хеш|-> <cfg> → версия go-installer.sh в ветке, rc 0.
# rc 1 — в коммите скрипта нет (404 или номера версии нет); rc 2 — ответа
# нет (сеть, 5xx после повторов, 403): «нет» сказать нельзя. Версия на
# коммите не меняется: тот же хеш — ответ из кеша «.sha» (общий с
# self_fetch_versions) без скачивания. «Скрипта нет» (строка с одним хешем)
# верно SELF_NONE_TTL минут: raw только что запушенного коммита бывает 404,
# навсегда это не запоминаем. Иначе — начало файла: номер версии в первых
# строках, весь файл (сотни КБ) ради него не нужен.
_self_probe() {
    local ref="$1" sha="$2" cfg="$3" shaf s0="" v0="" tmp v="" at code
    [ "$sha" = - ] && sha=""
    shaf="$(_ver_cache_file "$SELF_ID" "$ref").sha"
    if [ -n "$sha" ] && [ -r "$shaf" ]; then read -r s0 v0 < "$shaf" 2>/dev/null || s0=""; fi
    if [ -n "$sha" ] && [ "$s0" = "$sha" ]; then
        if [ -n "$v0" ]; then printf '%s' "$v0"; return 0; fi
        [ -n "$(find "$shaf" -mmin "-${SELF_NONE_TTL}" 2>/dev/null)" ] && return 1
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-selfp.XXXXXX") || return 2
    at="${sha:-$ref}"
    code=$(gh_curl --config "$cfg" --max-time "${GOINST_VER_TIMEOUT:-$GH_MT}" -r 0-16383 -o "$tmp" -w '%{http_code}' \
        "https://raw.githubusercontent.com/${GOINST_SELF_REPO}/${at}/go-installer.sh" 2>/dev/null) || true
    case "$code" in
        200|206) v=$(ver_extract "$tmp" "GOINST_VERSION") || v="" ;;
        404) ;;
        # Сбой сети, 5xx, 403 — в другой раз ответят иначе: не запоминаем.
        *) rm -f "$tmp"; return 2 ;;
    esac
    [ -n "$sha" ] && { printf '%s %s\n' "$sha" "$v" > "$shaf" 2>/dev/null || true; }
    rm -f "$tmp"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# self_ref_find <куда> → ветка ровно этой версии (GOINST_VERSION): rc 0, её
# go-installer.sh в <куда>, напечатано имя ветки. rc 1 — такой ветки нет.
# rc 2 — сказать нельзя; напечатана причина словом (_self_find_why):
#   limit — лимит запросов GitHub; net — GitHub не отвечает (сеть);
#   key — ключ не принят (401); fail — ответ с ошибкой, опрошены не все ветки;
#   many <ветки> — эта версия в нескольких ветках с разным содержимым: из
#   какой запускали, не узнать, и выбирать молча нельзя.
# Порядок: GOINST_SELF_REF, запомненная, dev, прочие по списку GitHub — не
# больше SELF_FIND_MAX. Ключ клуба один на всех: к API — один запрос (список
# веток с хешами голов; повтор с ETag лимит не тратит); не дали список — ещё
# по запросу хеша на каждую из своих веток (main, запомненная, dev). Файлы —
# с raw по хешу.
self_ref_find() {
    local dest="$1" cfg list res pairs cands ref sha st v at k f n="" n2 i=0 lrc=0 lcode="" fail=0
    local GH_SAY=1 GH_DOWN_FILE="" GH_WHAT=""
    local -a pids=() hits=() hfile=() hsha=()
    [ -z "${GOINST_NO_NET:-}" ] || { echo net; return 2; }
    [ -n "$TOKEN" ] && command -v curl >/dev/null 2>&1 || { echo fail; return 2; }
    gh_limited >/dev/null && { echo limit; return 2; }
    mkdir -p "$VER_CACHE" 2>/dev/null || { echo fail; return 2; }
    cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-self.XXXXXX") || { echo fail; return 2; }
    chmod 600 "$cfg"
    { echo 'silent'; echo 'location'; echo 'fail'; gh_cfg_net
      printf 'header = "Authorization: token %s"\n' "$TOKEN"; } > "$cfg"
    # Сети нет — первый исчерпавший попытки запрос ставит метку, прочие не ждут.
    GH_DOWN_FILE=$(mktemp "${TMPDIR:-/tmp}/goinst-down.XXXXXX") || GH_DOWN_FILE=""
    list=$(mktemp "${TMPDIR:-/tmp}/goinst-selfr.XXXXXX") || { rm -f "$cfg" ${GH_DOWN_FILE:+"$GH_DOWN_FILE"}; echo fail; return 2; }
    res=$(mktemp -d "${TMPDIR:-/tmp}/goinst-selfv.XXXXXX") || { rm -f "$cfg" "$list" ${GH_DOWN_FILE:+"$GH_DOWN_FILE"}; echo fail; return 2; }
    # Поиск идёт на глазах: без строки до ответа на мёртвой сети было бы
    # минуты тишины. Повторы списка — на экран (GH_SAY=1), проб — нет: они
    # параллельные, строки перемешались бы.
    say "$(bi "Ищу ветку ${GOINST_SELF_REPO} с версией ${GOINST_VERSION}…" "Looking for the ${GOINST_SELF_REPO} branch with version ${GOINST_VERSION}…")"
    GH_WHAT="$(bi "Список веток" "Branch list") ${GOINST_SELF_REPO}"
    GH_GET_CODE=""
    gh_get "https://api.github.com/repos/${GOINST_SELF_REPO}/branches?per_page=100" "$cfg" "$list" || lrc=$?
    lcode="$GH_GET_CODE"
    pairs=""; [ "$lrc" -eq 0 ] && pairs=$(_self_branch_pairs < "$list")
    if [ "$lrc" -eq 2 ]; then
        cands="" n=limit
    elif [ -n "$GH_DOWN_FILE" ] && [ -s "$GH_DOWN_FILE" ]; then
        cands="" n=net
    elif [ "$lcode" = 401 ]; then
        cands="" n=key
    elif [ -n "$pairs" ]; then
        n=""
        # Хеш — из списка; ветки, которой в списке нет, не спрашиваем.
        cands=$({ printf '%s\n' "$GOINST_SELF_REF"; self_ref_saved; echo; echo dev; cut -d' ' -f1 <<<"$pairs"; } |
                awk 'NF && !seen[$0]++' | while IFS= read -r ref; do
                    sha=$(awk -v r="$ref" '$1 == r { print $2; exit }' <<<"$pairs")
                    [ -n "$sha" ] && printf '%s %s\n' "$ref" "$sha"
                done)
    else
        n=""
        # Список не получен — хотя бы свои ветки, хеш спросит ref_sha.
        cands=$({ printf '%s\n' "$GOINST_SELF_REF"; self_ref_saved; echo; echo dev; } | awk 'NF && !seen[$0]++' | sed 's/$/ -/')
    fi
    GH_SAY=""
    while read -r ref sha; do
        [ -n "$ref" ] || continue
        _self_ref_ok "$ref" || continue
        case "$sha" in -) ;; *) [ "${#sha}" -eq 40 ] && [ -z "${sha//[0-9a-f]/}" ] || continue ;; esac
        [ "$i" -lt "$SELF_FIND_MAX" ] || break
        i=$(( i + 1 ))
        ( if [ "$sha" = - ]; then sha=$(ref_sha "$GOINST_SELF_REPO" "$ref" "$cfg") || sha=-; fi
          v=$(_self_probe "$ref" "$sha" "$cfg"); st=$?
          printf '%s %s %s %s\n' "$ref" "$sha" "$st" "$v" > "$res/$i" ) &
        pids+=("$!")
    done <<<"$cands"
    # Ждём только свои запросы: у меню бывают другие фоновые задачи.
    [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}" 2>/dev/null
    # Каждая ветка этой версии — целиком, с той же проверкой, что у
    # self_update: скрипт, эта версия, разбирается bash. Тот же хеш — тот же
    # файл, второй раз не качаем.
    GH_SAY=1
    for (( k = 1; k <= i; k++ )); do
        ref=""; sha=""; st=2; v=""
        read -r ref sha st v < "$res/$k" 2>/dev/null || { fail=1; continue; }
        [ "$st" = 2 ] && fail=1
        [ "$st" = 0 ] && [ "$v" = "$GOINST_VERSION" ] || continue
        f=""
        if [ "$sha" != - ]; then
            for (( n2 = 0; n2 < ${#hits[@]}; n2++ )); do [ "${hsha[$n2]}" = "$sha" ] && f="${hfile[$n2]}"; done
        fi
        if [ -z "$f" ]; then
            at="$sha"; [ "$at" = - ] && at="$ref"
            f="$res/f.$k"
            GH_WHAT="go-installer.sh ($(bi "ветка" "branch") ${ref})"
            if ! { gh_curl --config "$cfg" --max-time 180 -o "$f" \
                       "https://raw.githubusercontent.com/${GOINST_SELF_REPO}/${at}/go-installer.sh" >/dev/null &&
                   looks_like_script "$f" && [ "$(ver_extract "$f" "GOINST_VERSION")" = "$GOINST_VERSION" ] &&
                   bash -n "$f" 2>/dev/null; }; then
                fail=1; continue
            fi
        fi
        hits+=("$ref"); hfile+=("$f"); hsha+=("$sha")
    done
    if [ "${#hits[@]}" -gt 0 ]; then
        for (( k = 1; k < ${#hits[@]}; k++ )); do
            cmp -s "${hfile[0]}" "${hfile[$k]}" && continue
            n="many ${hits[*]}"; break
        done
        if [ -z "$n" ] && cp -f "${hfile[0]}" "$dest" 2>/dev/null; then n="ok"; fi
    fi
    # Сеть пропала посреди опроса — «такой ветки нет» сказать нельзя.
    if [ -z "$n" ]; then
        if [ -n "$GH_DOWN_FILE" ] && [ -s "$GH_DOWN_FILE" ]; then n=net
        elif [ "$lrc" -ne 0 ] || [ -z "$pairs" ] || [ "$fail" -eq 1 ] || [ "${#hits[@]}" -gt 0 ]; then n=fail
        fi
    fi
    rm -rf "$cfg" "$list" "$res" ${GH_DOWN_FILE:+"$GH_DOWN_FILE"}
    case "$n" in
        ok) printf '%s' "${hits[0]}"; return 0 ;;
        "") return 1 ;;
    esac
    printf '%s' "$n"
    return 2
}
# _self_find_why <rc> <причина self_ref_find> → почему ветку не взяли, словами.
_self_find_why() {
    local w="${2%% *}" l="${2#* }"
    [ "$1" -eq 1 ] && { bi "ни в одной ветке ${GOINST_SELF_REPO} нет версии ${GOINST_VERSION}" "no ${GOINST_SELF_REPO} branch has version ${GOINST_VERSION}"; return 0; }
    case "$w" in
        limit) bi "ветки ${GOINST_SELF_REPO} не опросить: исчерпан общий лимит запросов GitHub, снова заработает к $(gh_reset_text)" "the ${GOINST_SELF_REPO} branches cannot be listed: the shared GitHub request limit is used up until $(gh_reset_text)" ;;
        net)   bi "ветки ${GOINST_SELF_REPO} не опросить: GitHub не ответил (сеть)" "the ${GOINST_SELF_REPO} branches cannot be listed: GitHub did not answer (network)" ;;
        key)   bi "ветки ${GOINST_SELF_REPO} не опросить: GitHub не принял ключ (ответ 401)" "the ${GOINST_SELF_REPO} branches cannot be listed: GitHub did not accept the key (answer 401)" ;;
        many)  bi "версия ${GOINST_VERSION} есть в нескольких ветках ${GOINST_SELF_REPO} с разным содержимым (${l// /, }) — из какой запускали, не узнать" "version ${GOINST_VERSION} is in several ${GOINST_SELF_REPO} branches with different contents (${l// /, }) — which one was run cannot be told" ;;
        *)     bi "ветки ${GOINST_SELF_REPO} опрошены не все: GitHub ответил ошибкой" "not all ${GOINST_SELF_REPO} branches could be checked: GitHub answered with an error" ;;
    esac
}

# Что сделать, чтобы goinstall стал этой версией, — для отказов: точная
# команда, если ветка этой версии известна (и goinstall ещё не она); эта
# версия в нескольких ветках, а goinstall есть, — обновить его из нужной;
# иначе — запуск из файла. Команда — в конце, без точки: её копируют.
self_fix_hint() {
    if [ -n "$SELF_REF_HIT" ] && ! grep -qx "GOINST_VERSION=\"${GOINST_VERSION}\"" "$GOINST_BIN" 2>/dev/null; then
        bi "запустите goinstall снова, обновив команду: goinstall --self-update ${SELF_REF_HIT}" "start goinstall again after updating the command: goinstall --self-update ${SELF_REF_HIT}"
        return 0
    fi
    if [ -n "$SELF_REF_MANY" ] && [ -f "$GOINST_BIN" ] && looks_like_script "$GOINST_BIN" &&
       ! grep -qx "GOINST_VERSION=\"${GOINST_VERSION}\"" "$GOINST_BIN" 2>/dev/null; then
        bi "обновите команду из нужной ветки (${SELF_REF_MANY// /, }) и запустите goinstall снова: goinstall --self-update <ветка>" "update the command from the right branch (${SELF_REF_MANY// /, }) and start goinstall again: goinstall --self-update <branch>"
        return 0
    fi
    bi "запустите скрипт из файла — той ветки, из которой запускали: curl -fsSL -H \"Authorization: token <ключ>\" -o go-installer.sh https://raw.githubusercontent.com/${GOINST_SELF_REPO}/<ветка>/go-installer.sh && bash go-installer.sh" \
       "run the script from a file — of the branch you ran it from: curl -fsSL -H \"Authorization: token <key>\" -o go-installer.sh https://raw.githubusercontent.com/${GOINST_SELF_REPO}/<branch>/go-installer.sh && bash go-installer.sh"
}

# Файл — в goinstall: рядом и переставить. Идущий goinstall (меню в соседнем
# окне) дочитывает прежний файл, а не обрывок нового. Временный файл — свой
# у каждого запуска (REVIEW-8 №4): два окна с общим goinstall.new могли
# переставить недописанный.
_self_put() {
    local n
    n=$(mktemp "${GOINST_BIN}.XXXXXX" 2>/dev/null) || return 1
    if cp -f "$1" "$n" 2>/dev/null && chmod 755 "$n" && mv -f "$n" "$GOINST_BIN"; then
        ln -sf "$GOINST_BIN" "$GOINST_BIN_ALIAS" 2>/dev/null || true
        return 0
    fi
    rm -f "$n" 2>/dev/null
    return 1
}

# Чтобы после первого запуска была команда goinstall. При `bash <(curl…)`
# $0 — не файл; тогда качаем свою копию из репозитория (ключ уже есть):
# ветку ровно этой версии. Не нашлась: goinstall нет — ставим
# GOINST_SELF_REF, как раньше; goinstall есть — другой версией его молча не
# заменяем, а говорим, как быть. Сеть не отвечает или версия в нескольких
# ветках с разным содержимым — не ставим и GOINST_SELF_REF: в первом случае
# ждали бы второй круг повторов, во втором таймер защиты получил бы чужой код.
# Запись .self-ref — ветка того, что стоит в goinstall: поставили не из
# найденной ветки — запись стирается (self_ref_remember GOINST_SELF_REF),
# иначе обновления без ветки уводили бы на прежнюю.
# Тот же номер: из файла сверяется содержимое — другая сборка того же номера
# (К5-11) ставится, как другой номер: запущенный файл — то, что выбрал
# человек, а копия таймера идёт за goinstall (shield_runner_src). Из канала
# сверить не с чем — goinstall остаётся, копия таймера — тоже его.
self_install() {
    local same=""
    [ -n "${GOINST_NO_SELF_INSTALL:-}" ] && return 0
    # Пока идёт обновление Ubuntu, свой файл не переписываем.
    osup_busy && return 0
    if [ -x "$GOINST_BIN" ] && grep -q "GOINST_VERSION=\"${GOINST_VERSION}\"" "$GOINST_BIN" 2>/dev/null; then
        { [ -f "$0" ] && looks_like_script "$0" && ! cmp -s "$0" "$GOINST_BIN"; } || return 0
        same=1
    fi
    if [ -f "$0" ] && looks_like_script "$0"; then
        # Рядом и переставить (_self_put): goinstall того же номера может
        # идти в соседнем окне — он дочитает прежний файл.
        if _self_put "$0"; then
            # Тот же номер — та же ветка: запись не трогаем (REVIEW-8 №2);
            # когда main догонит, её сотрёт _self_ref_caught.
            [ -n "$same" ] || self_ref_remember "$GOINST_SELF_REF"
            if [ -n "$same" ]; then
                ok "$(bi "Команда goinstall заменена запущенным файлом: та же версия ${GOINST_VERSION}, другая сборка." "The goinstall command is replaced by the file being run: the same version ${GOINST_VERSION}, a different build.")"
                shield_log "$(bi "goinstall заменён другой сборкой версии ${GOINST_VERSION} (из файла)" "goinstall is replaced by another build of version ${GOINST_VERSION} (from a file)")"
            else
                ok "$(bi "Команда goinstall установлена." "The goinstall command is installed.")"
            fi
        fi
        return 0
    fi
    [ -n "$TOKEN" ] || return 0
    local tmp ref rc=0 hv why
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-self.XXXXXX") || return 0
    if ref=$(self_ref_find "$tmp"); then
        SELF_REF_HIT="$ref"
        if _self_put "$tmp"; then
            self_ref_remember "$ref"
            ok "$(bi "Команда goinstall установлена: версия ${GOINST_VERSION} из ветки ${ref}." "The goinstall command is installed: version ${GOINST_VERSION} from branch ${ref}.")"
            shield_self_update_note "$GOINST_BIN"
        else
            warn "$(bi "Не удалось записать ${GOINST_BIN} — команда goinstall не обновлена." "Could not write ${GOINST_BIN} — the goinstall command is not updated.")"
        fi
    else
        rc=$?
        case "$ref" in "many "*) SELF_REF_MANY="${ref#many }" ;; esac
        why=$(_self_find_why "$rc" "$ref")
        if [ -f "$GOINST_BIN" ] && looks_like_script "$GOINST_BIN"; then
            hv=$(ver_extract "$GOINST_BIN" "GOINST_VERSION") || hv="?"
            warn "$(bi "Команда goinstall оставлена прежней (версия ${hv}): ${why}. Другой версией её не заменяю. Чтобы goinstall стал версией ${GOINST_VERSION}, $(self_fix_hint)" "The goinstall command is left as it was (version ${hv}): ${why}. I do not replace it with another version. To make goinstall version ${GOINST_VERSION}, $(self_fix_hint)")"
        elif [ "$rc" -eq 2 ] && { [ "$ref" = net ] || [ -n "$SELF_REF_MANY" ]; }; then
            warn "$(bi "Команда goinstall не установлена: ${why}. Чтобы она появилась, $(self_fix_hint)" "The goinstall command is not installed: ${why}. To get it, $(self_fix_hint)")"
        elif fetch_raw "$GOINST_SELF_REPO" "$GOINST_SELF_REF" "go-installer.sh" "$tmp" 2>/dev/null; then
            if _self_put "$tmp"; then
                self_ref_remember "$GOINST_SELF_REF"
                ok "$(bi "Команда goinstall установлена." "The goinstall command is installed.")"
                shield_self_update_note "$GOINST_BIN"
            fi
        fi
    fi
    rm -f "$tmp"
    return 0
}

# ── меню: один набор пунктов, два способа его показать ──────────────────
# Пункты объявляются ОДИН раз в MENU_ITEMS, рисуются либо стрелочным
# экраном, либо нумерованным списком. Второго набора пунктов нет нигде:
# разойдясь, они дали бы пункт, который виден в одном режиме и недоступен
# в другом.
#
# Строка пункта: "ключ|имя|цвет:статус|цвет:доступно|подпись".
# Ключ "-" — разделитель (пропускается при ходьбе стрелками).
# Цвет: g зелёный, y жёлтый, r красный, d приглушённый.
MENU_TITLE=""; MENU_SUB=""; MENU_ITEMS=(); PICK_KEY=""
MENU_ROW=(); MENU_KEY=()

# Длина в СИМВОЛАХ. `${#s}` считает символы только при UTF-8-локали, а на
# сервере часто LANG=C — там кириллица в колонке разъезжается ровно вдвое.
# Продолжающие байты UTF-8 (10xxxxxx) символа не начинают: вычитаем их.
str_len() {
    local s="$1"
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) printf '%s' "${#s}"; return 0 ;;
    esac
    s="${s//[$'\x80'-$'\xbf']/}"
    printf '%s' "${#s}"
}

# str_cut <строка> <сколько символов> — обрезать, не порвав символ.
# Одна реализация на обе локали: в UTF-8 `${s:i:1}` возвращает символ и
# внутренний цикл просто не срабатывает, в C-локали — байт, и цикл
# дочитывает продолжения. Отдельной ветки «в C не режем» быть не должно:
# LANG под sudo и cron часто не задан вовсе, и такая ветка означала бы, что
# колонки разъезжаются именно там, где никто не смотрит.
str_cut() {
    local s="$1" w="$2" out="" i=0 n=0 len=${#s}
    while [ "$i" -lt "$len" ] && [ "$n" -lt "$w" ]; do
        out+="${s:i:1}"; i=$((i+1))
        while [ "$i" -lt "$len" ]; do
            case "${s:i:1}" in
                [$'\x80'-$'\xbf']) out+="${s:i:1}"; i=$((i+1)) ;;
                *) break ;;
            esac
        done
        n=$((n+1))
    done
    printf '%s' "$out"
}

# cut_to <строка> <ширина> — обрезать до ширины, отметив обрез многоточием.
cut_to() {
    local s="$1" w="$2"
    if [ "$(str_len "$s")" -gt "$w" ]; then printf '%s…' "$(str_cut "$s" "$((w-1))")"
    else printf '%s' "$s"; fi
}

# cut_words <строка> <ширина> — как cut_to, но по границе слова: пояснение
# «продукты оста…» теряло смысл. Последнее слово отбрасывается, только если
# до него остаётся хотя бы половина ширины; висящие «,;:—» перед многоточием
# убираются.
cut_words() {
    local s="$1" w="$2" t n rest
    if [ "$(str_len "$s")" -le "$w" ]; then printf '%s' "$s"; return 0; fi
    [ "$w" -ge 2 ] || { cut_to "$s" "$w"; return 0; }
    t=$(str_cut "$s" "$((w-1))"); n=$(str_cut "$s" "$w"); rest="${n#"$t"}"
    if [ "$rest" != " " ] && [[ "$t" == *" "* ]] && [ "$(str_len "${t% *}")" -ge $(( w / 2 )) ]; then t="${t% *}"; fi
    while :; do
        case "$t" in
            *" ") t="${t% }" ;;  *",") t="${t%,}" ;;  *";") t="${t%;}" ;;
            *":") t="${t%:}" ;;  *"—") t="${t%—}" ;;  *"-") t="${t%-}" ;;
            *) break ;;
        esac
    done
    printf '%s…' "$t"
}

# pad_to <строка> <ширина> — дополнить пробелами до ширины в символах.
# Слишком длинное обрезаем: одно длинное имя иначе сдвигает всю строку.
pad_to() {
    local s="$1" w="$2" n
    n=$(str_len "$s")
    if [ "$n" -gt "$w" ]; then cut_to "$s" "$w"; return 0; fi
    printf '%s%*s' "$s" "$((w-n))" ''
}

_st_color() {
    case "$1" in
        g) printf '%s' "$GREEN" ;; y) printf '%s' "$YELLOW" ;;
        r) printf '%s' "$RED" ;;  *) printf '%s' "$DIM" ;;
    esac
}

# Строки готовим ЗАРАНЕЕ: перерисовка по нажатию клавиши должна быть чистым
# printf. Сборка строки дёргает pad_to и _st_color, и делать это на каждое
# нажатие — тот самый «список, который перезагружается».
menu_build_rows() {
    MENU_ROW=(); MENU_KEY=()
    local it key name st extra sub stc sttext exc extext
    local w_name="${MENU_W_NAME:-16}" w_st="${MENU_W_STATUS:-22}" w_ex="${MENU_W_EXTRA:-0}"
    # Служебные пункты главного меню (MENU_SVC: без колонки «доступно», с
    # пояснением) — пояснения в ОДНОЙ колонке svc_col и целиком: «продукты
    # оста…» теряло смысл. Колонка — первая, где помещаются все их пояснения и
    # подписи без состояния («Обновить сведения о версиях»): общая с
    # описаниями продуктов, потом сразу за самой длинной такой подписью, потом
    # сразу за состоянием (тогда длинное пояснение режется по слову).
    local svc="" svc_col=0 c ok nl sl
    if [ -n "${MENU_SVC:-}" ] && [ -n "${MENU_W_ROW:-}" ]; then
        local -a sn=() ss=()
        for it in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r key name st extra sub <<<"$it"
            [ "$key" = "-" ] || [ -z "$sub" ] || [ -n "${extra#?:}" ] && continue
            svc=1
            if [ "$(str_len "$name")" -gt "$w_name" ]; then
                # Длинная подпись с состоянием («o) Ubuntu 22.04 → 24.04») —
                # всегда своя раскладка, колонку она не решает.
                [ -n "${st#?:}" ] && continue
                sn+=("$(str_len "$name")")
            fi
            ss+=("$(str_len "$sub")")
        done
        if [ -n "$svc" ]; then
            local base=$(( w_name + 2 + w_st + 2 )) c0
            c0=$base; for nl in ${sn[@]+"${sn[@]}"}; do [ $(( nl + 2 )) -gt "$c0" ] && c0=$(( nl + 2 )); done
            c=$base; [ "$w_ex" -gt 0 ] && c=$(( c + w_ex + 2 )); [ "$c0" -gt "$c" ] && c=$c0
            ok=""
            for c in "$c" "$c0" "$base"; do
                ok=1
                for sl in ${ss[@]+"${ss[@]}"}; do [ "$sl" -le $(( MENU_W_ROW - c )) ] || ok=""; done
                for nl in ${sn[@]+"${sn[@]}"}; do [ "$nl" -le $(( c - 2 )) ] || ok=""; done
                [ -n "$ok" ] && break
            done
            # Не влезло нигде — за самой длинной подписью: подписи выровнены,
            # длинное пояснение режется по слову.
            [ -n "$ok" ] || c=$c0
            svc_col=$c
        fi
    fi
    for it in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r key name st extra sub <<<"$it"
        # «-» — разделитель. С подписью — строка для чтения: видна, но не
        # выбирается (движки продуктов в меню «Компоненты»).
        # Без имени, с подписью — строка пояснения под пунктом (кто обновляет
        # движок, как починить окружение бота); «r:» — красным.
        if [ "$key" = "-" ] && [ -z "$name" ] && [ -n "$sub" ]; then
            case "$sub" in r:*) MENU_ROW+=("${RED}${sub#r:}${NC}") ;; g:*) MENU_ROW+=("${GREEN}${sub#g:}${NC}") ;;
                y:*) MENU_ROW+=("${YELLOW}${sub#y:}${NC}") ;; *) MENU_ROW+=("${DIM}${sub}${NC}") ;; esac
            MENU_KEY+=("-"); continue
        fi
        if [ "$key" = "-" ] && [ -z "$name" ]; then MENU_ROW+=(""); MENU_KEY+=("-"); continue; fi
        if [ "$key" = "-" ] && [ -z "$st$extra$sub" ]; then MENU_ROW+=("${BOLD}${name}${NC}"); MENU_KEY+=("-"); continue; fi
        stc="${st%%:*}"; sttext="${st#*:}"
        case "$stc" in g|y|r|d) ;; *) stc="d"; sttext="$st" ;; esac
        exc="${extra%%:*}"; extext="${extra#*:}"
        case "$exc" in g|y|r|d) ;; *) exc="d"; extext="$extra" ;; esac
        # Подпись шире колонки имени (колонку держат пояснения продуктов) —
        # строка своей раскладкой: имя целиком, состояние, пояснение — сколько
        # влезет в окно. Иначе «Ubuntu 22.04 → 24.04» резалось бы посередине.
        if [ -n "${MENU_W_ROW:-}" ] && [ "$(str_len "$name")" -gt "$w_name" ]; then
            local row="$name" room col
            # Ни состояния, ни версии («r) Обновить сведения о версиях», «x)
            # Удалить goInstaller») — пояснение в колонку служебных пунктов,
            # если имя до неё помещается, а пояснение за ней — целиком: своя
            # раскладка ставила его вплотную к имени.
            if [ -n "$svc" ] && [ -z "$sttext" ] && [ -z "$extext" ] && [ -n "$sub" ] && [ "$(str_len "$name")" -le $(( svc_col - 2 )) ] \
                && [ "$(str_len "$sub")" -le $(( MENU_W_ROW - svc_col )) ]; then
                MENU_ROW+=("$(pad_to "$name" "$svc_col")${DIM}${sub}${NC}"); MENU_KEY+=("$key"); continue
            fi
            col=$(( w_name + 2 + w_st + 2 )); [ "$w_ex" -gt 0 ] && col=$(( col + w_ex + 2 ))
            if [ -z "$svc" ] && [ -z "$sttext" ] && [ -z "$extext" ] && [ -n "$sub" ] && [ "$(str_len "$name")" -le $(( col - 2 )) ]; then
                case "${MENU_W_SUB:-}" in ''|*[!0-9]*|0) ;; *)
                    MENU_ROW+=("$(pad_to "$name" "$col")${DIM}$(cut_words "$sub" "$MENU_W_SUB")${NC}"); MENU_KEY+=("$key"); continue ;;
                esac
            fi
            room=$(( MENU_W_ROW - $(str_len "$name") ))
            [ -n "$sttext" ] && { row+="  $(_st_color "$stc")${sttext}${NC}"; room=$(( room - 2 - $(str_len "$sttext") )); }
            [ -n "$extext" ] && [ "$w_ex" -gt 0 ] && { row+="  $(_st_color "$exc")${extext}${NC}"; room=$(( room - 2 - $(str_len "$extext") )); }
            if [ -n "$sub" ] && [ "$room" -ge 10 ]; then row+="  ${DIM}$(cut_words "$sub" $(( room - 2 )))${NC}"; fi
            MENU_ROW+=("$row"); MENU_KEY+=("$key"); continue
        fi
        # Пункт-действие без колонок («a) Обновить всё (3)») — имя целиком:
        # колонка имени ему не нужна, а обрезанное число теряло смысл.
        if [ -z "$st" ] && [ -z "$extra" ]; then
            [ -n "$sub" ] && case "${MENU_W_SUB:-}" in ''|*[!0-9]*|0) ;; *) sub=$(cut_to "$sub" $(( MENU_W_SUB + w_name + w_st - $(str_len "$name") ))) ;; esac
            MENU_ROW+=("$(printf '%s  %s%s%s' "$name" "$DIM" "$sub" "$NC")"); MENU_KEY+=("$key"); continue
        fi
        # Подпись обрезаем по ширине окна: перенос длинной строки сбил бы
        # раскладку экрана — на каждый пункт стало бы по две строки.
        # Служебный пункт — пояснение в колонке svc_col.
        if [ -n "$svc" ] && [ -z "$extext" ] && [ -n "$sub" ]; then
            if [ $(( MENU_W_ROW - svc_col )) -ge 12 ]; then sub=$(cut_words "$sub" $(( MENU_W_ROW - svc_col ))); else sub=""; fi
            MENU_ROW+=("$(printf '%s  %s%s%s  %s%s%s' \
                "$(pad_to "$name" "$w_name")" \
                "$(_st_color "$stc")" "$(pad_to "$sttext" $(( svc_col - w_name - 4 )))" "$NC" \
                "$DIM" "$sub" "$NC")")
            MENU_KEY+=("$key"); continue
        fi
        case "${MENU_W_SUB:-}" in
            ''|*[!0-9]*) ;;
            0) sub="" ;;
            *) sub=$(cut_words "$sub" "$MENU_W_SUB") ;;
        esac
        if [ "$w_ex" -gt 0 ]; then
            MENU_ROW+=("$(printf '%s  %s%s%s  %s%s%s  %s%s%s' \
                "$(pad_to "$name" "$w_name")" \
                "$(_st_color "$stc")" "$(pad_to "$sttext" "$w_st")" "$NC" \
                "$(_st_color "$exc")" "$(pad_to "$extext" "$w_ex")" "$NC" \
                "$DIM" "$sub" "$NC")")
        else
            MENU_ROW+=("$(printf '%s  %s%s%s  %s%s%s' \
                "$(pad_to "$name" "$w_name")" \
                "$(_st_color "$stc")" "$(pad_to "$sttext" "$w_st")" "$NC" \
                "$DIM" "$sub" "$NC")")
        fi
        MENU_KEY+=("$key")
    done
}

# menu_cols — ширина окна для нумерованного меню.
menu_cols() {
    local c; c=$(tput cols 2>/dev/null) || c=""
    case "$c" in ''|*[!0-9]*) c="${COLUMNS:-80}" ;; esac
    case "$c" in ''|*[!0-9]*) c=80 ;; esac
    printf '%s' "$c"
}
# menu_fit_widths <наименьшая ширина имени> [наименьшее пояснение] — колонка
# имени по самой длинной подписи пункта (с фиксированной 16 «Обновить
# сведения о версиях» резалась), но так, чтобы строка без пояснения влезала в
# окно, а пояснению оставалось не меньше второго числа: в главном меню это
# описания продуктов, и терять их ради длинной служебной подписи нельзя.
# Подпись шире колонки строка кладёт своей раскладкой (menu_build_rows).
# Потом MENU_W_SUB — сколько осталось на пояснение (меньше 12 — не показывать).
# Третий аргумент — образец ключей, по которым считается колонка имени (в
# главном меню — продукты): длинные служебные подписи ложатся своей
# раскладкой, и раздувать ради них колонку значит отнять место у описаний.
menu_fit_widths() {
    local min="$1" msub="${2:-0}" keys="${3:-}" cols it key name st extra sub l w=0 fixed
    cols=$(menu_cols)
    for it in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r key name st extra sub <<<"$it"
        [ -n "$name" ] || continue
        [ "$key" = "-" ] && [ -z "$st$extra$sub" ] && continue
        # shellcheck disable=SC2254
        [ -n "$keys" ] && case "$key" in $keys) ;; *) continue ;; esac
        l=$(str_len "$name"); [ "$l" -gt "$w" ] && w=$l
    done
    fixed=$(( 6 + 2 + MENU_W_STATUS ))
    [ "${MENU_W_EXTRA:-0}" -gt 0 ] && fixed=$(( fixed + MENU_W_EXTRA + 2 ))
    [ "$w" -gt $(( cols - fixed )) ] && w=$(( cols - fixed ))
    [ "$msub" -gt 0 ] && [ "$w" -gt $(( cols - fixed - 2 - msub )) ] && w=$(( cols - fixed - 2 - msub ))
    [ "$w" -lt "$min" ] && w=$min
    MENU_W_NAME=$w; MENU_W_ROW=$(( cols - 6 ))
    if [ -n "$keys" ]; then MENU_SVC=1; else MENU_SVC=""; fi
    MENU_W_SUB=$(( cols - fixed - w - 2 ))
    [ "$MENU_W_SUB" -lt 12 ] && MENU_W_SUB=0
    return 0
}

# Стрелочный экран годится не всегда: под `curl | bash` stdin занят, в
# тестах терминала нет вовсе, а в коротком окне перерисовка от \033[H
# дерётся с прокруткой. Во всех этих случаях — нумерованный список.
menu_is_interactive() {
    [ -z "${GOINST_PLAIN_MENU:-}" ] || return 1
    [ -t 0 ] && [ -t 1 ] || return 1
    case "${TERM:-dumb}" in dumb|'') return 1 ;; esac
    local lines need
    lines=$(tput lines 2>/dev/null) || lines=""
    case "$lines" in ''|*[!0-9]*) lines=24 ;; esac
    need=$(( ${#MENU_ITEMS[@]} + 8 ))
    [ "$lines" -ge "$need" ]
}

_menu_next() {  # _menu_next <текущий> <шаг> — ход с пропуском разделителей
    local cur="$1" step="$2" n="${#MENU_KEY[@]}" i=0
    while [ "$i" -lt "$n" ]; do
        cur=$(( (cur + step + n) % n ))
        [ "${MENU_KEY[$cur]}" = "-" ] || { printf '%s' "$cur"; return 0; }
        i=$((i+1))
    done
    printf '%s' "$1"
}

_menu_paint() {
    local cur="$1" i n
    printf '\033[H'
    printf '  %b\033[K\n' "${CYAN}${BOLD}${MENU_TITLE}${NC}"
    [ -n "$MENU_SUB" ] && printf '  %b\033[K\n' "${DIM}${MENU_SUB}${NC}"
    printf '  %b\033[K\n' "${DIM}$(printf '─%.0s' {1..60})${NC}"
    n=${#MENU_ROW[@]}
    for ((i=0; i<n; i++)); do
        if [ "${MENU_KEY[$i]}" = "-" ]; then printf '    %b\033[K\n' "${MENU_ROW[$i]}"; continue; fi
        if [ "$i" -eq "$cur" ]; then
            printf '  %b%b\033[K\n' "${CYAN}▸ ${NC}${BOLD}" "${MENU_ROW[$i]}${NC}"
        else
            printf '    %b\033[K\n' "${MENU_ROW[$i]}"
        fi
    done
    printf '\033[K\n'
    if [ -n "${MENU_FOOTER_INFO:-}" ]; then printf '  %b\033[K\n' "${DIM}${MENU_FOOTER_INFO}${NC}"; fi
    printf '  %b\033[K\n' "${DIM}$(bi "↑↓ выбрать · Enter открыть · цифра сразу · q выход" "↑↓ move · Enter open · digit jumps · q quit")${NC}"
    printf '\033[J'
}

# Нажатие кладём в KEY, без подстановки команд: подстановка — это ещё один
# процесс на КАЖДОЕ нажатие.
KEY=""
_menu_read_key() {
    local k rest="" rc t="${1:-}"
    KEY=""
    if [ -n "$t" ]; then IFS= read -rsn1 -t "$t" k; rc=$?
    else IFS= read -rsn1 k; rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        # Код больше 128 — вышло время ожидания, а не конец ввода. Спутать
        # их значит выходить из меню каждые три минуты.
        if [ "$rc" -gt 128 ]; then KEY="tick"; else KEY="quit"; fi   # Ctrl-D — выход
        return 0
    fi
    case "$k" in
        '')  KEY="enter"; return 0 ;;                        # Enter — открыть
        q|Q) KEY="quit";  return 0 ;;
        $'\033')
            IFS= read -rsn2 -t 0.2 rest 2>/dev/null || rest=""
            case "$rest" in
                '[A') KEY="up" ;;   '[B') KEY="down" ;;
                '[C') KEY="enter" ;; '[D') KEY="quit" ;;
                '')   KEY="quit" ;;                          # голый Esc
                *)    KEY="other" ;;
            esac
            return 0 ;;
        *) KEY="$k"; return 0 ;;
    esac
}

_menu_restore() { printf '\033[?25h\n'; }
# Русская раскладка — те же буквы, что у «Аркады» (з — p, с — c, ы — s…).
_menu_ru_key() {
    case "$KEY" in
        з|З) KEY=p ;; к|К) KEY=r ;; д|Д) KEY=l ;; г|Г) KEY=u ;; й|Й) KEY=quit ;;
        с|С) KEY=c ;; ф|Ф) KEY=a ;; щ|Щ) KEY=o ;; ы|Ы) KEY=s ;;
    esac
}

# pick_menu → PICK_KEY, rc 0 выбрано / 1 отменено.
pick_menu() {
    PICK_KEY=""
    menu_build_rows
    menu_is_interactive || { _pick_menu_plain; return $?; }
    local cur n i left refresh="${MENU_REFRESH_SEC:-0}" next_at=0
    n=${#MENU_KEY[@]}
    [ "$n" -gt 0 ] || return 1
    cur=0; [ "${MENU_KEY[0]}" = "-" ] && cur=$(_menu_next 0 1)
    # Ctrl-C не должен оставить терминал без курсора. EXIT не трогаем:
    # ловушка на нём — общая для скрипта, и своя её бы затёрла.
    trap '_menu_restore; exit 130' INT
    case "$refresh" in ''|*[!0-9]*) refresh=0 ;; esac
    [ "$refresh" -gt 0 ] && next_at=$(( SECONDS + refresh ))
    printf '\033[?25l'; clear
    while true; do
        _menu_paint "$cur"
        # Отсчёт от SECONDS, а не «тайм-аут на каждое чтение»: иначе любое
        # нажатие клавиши отодвигало бы обновление ещё на три минуты.
        if [ "$refresh" -gt 0 ]; then
            left=$(( next_at - SECONDS )); [ "$left" -ge 1 ] || left=1
            _menu_read_key "$left"
        else
            _menu_read_key
        fi
        case "$KEY" in
            tick)
                # Обновление на месте: без clear и без выхода из меню, курсор
                # остаётся где был. Иначе раз в три минуты человека
                # выбрасывало бы наверх списка посреди чтения.
                if [ -n "${MENU_REFRESH_HOOK:-}" ]; then "$MENU_REFRESH_HOOK" >/dev/null 2>&1 || true; fi
                menu_build_rows
                n=${#MENU_KEY[@]}
                [ "$n" -gt 0 ] || { PICK_KEY=""; break; }
                [ "$cur" -lt "$n" ] || cur=0
                [ "${MENU_KEY[$cur]}" = "-" ] && cur=$(_menu_next "$cur" 1)
                next_at=$(( SECONDS + refresh )) ;;
            up)    cur=$(_menu_next "$cur" -1) ;;
            down)  cur=$(_menu_next "$cur" 1) ;;
            enter) PICK_KEY="${MENU_KEY[$cur]}"; break ;;
            quit)  PICK_KEY=""; break ;;
            other) ;;
            *)
                _menu_ru_key
                [ "$KEY" = quit ] && { PICK_KEY=""; break; }
                for ((i=0; i<n; i++)); do
                    if [ "${MENU_KEY[$i]}" = "$KEY" ]; then PICK_KEY="$KEY"; break 2; fi
                done ;;
        esac
    done
    trap - INT
    printf '\033[?25h'; clear
    [ -n "$PICK_KEY" ] || return 1
    return 0
}

_pick_menu_plain() {
    local i n c KEY
    while true; do
        print_header "$MENU_TITLE"
        [ -n "$MENU_SUB" ] && echo -e "  ${DIM}${MENU_SUB}${NC}" >&2
        echo "" >&2
        n=${#MENU_ROW[@]}
        for ((i=0; i<n; i++)); do
            if [ "${MENU_KEY[$i]}" = "-" ]; then if [ -n "${MENU_ROW[$i]}" ]; then printf "     %b\n" "${MENU_ROW[$i]}" >&2; else echo "" >&2; fi; continue; fi
            printf "  ${CYAN}%s)${NC} %b\n" "${MENU_KEY[$i]}" "${MENU_ROW[$i]}" >&2
        done
        echo "" >&2
        read_line c || { PICK_KEY=""; return 1; }
        n=${#MENU_KEY[@]}
        for ((i=0; i<n; i++)); do
            if [ "${MENU_KEY[$i]}" = "$c" ]; then PICK_KEY="$c"; return 0; fi
        done
        # Русская раскладка — как в стрелочном меню: «ы» — s, «з» — p.
        KEY="$c"; _menu_ru_key
        for ((i=0; i<n; i++)); do
            if [ "${MENU_KEY[$i]}" = "$KEY" ]; then PICK_KEY="$KEY"; return 0; fi
        done
        warn "$(bi "Неверный ввод." "Invalid input.")"; sleep 1
    done
}

# ── готовность продукта к установке ─────────────────────────────────────
# Считается тем же preflight, тихо: второй набор правил рядом с первым
# разошёлся бы с ним — и меню обещало бы «готов» там, где проверка
# отказывает.
_pf_first_blocker() {
    local f1 f2 f3 f4 who
    while IFS='|' read -r f1 f2 f3 f4 _; do
        [ -n "$f1" ] || continue
        if [ "$f1" = "os" ] && [ "$f2" = "must" ]; then
            printf '%s' "$(bi "система не подходит" "unsupported OS")"; return 0
        fi
        if [ "$f1" = "rule" ] && [ "$f2" = "must" ]; then
            printf '%s' "$(bi "конфликт с соседом" "neighbour conflict")"; return 0
        fi
        if [ "$f2" = "busy" ] && [ "$f3" = "must" ]; then
            case "$f4" in
                system) who=$(bi "система" "system") ;;
                nginx)  who="nginx" ;;
                *)      who=$(prod_name "$f4") ;;
            esac
            printf '%s %s: %s' "${f1%%/*}" "$(bi "занят" "busy")" "$who"; return 0
        fi
    done <<<"$PF_LINES"
    printf '%s' "$(bi "ставить нельзя" "cannot install")"
}

prod_readiness() {
    local id="$1" rc m first="" i=0 modes=()
    read -r -a modes <<<"$(prod_modes "$id")"
    [ "${#modes[@]}" -gt 0 ] || modes=(pro)
    for m in "${modes[@]}"; do
        preflight "$id" "$m" >/dev/null 2>&1; rc=$?
        if [ "$i" -eq 0 ]; then
            case "$rc" in
                0) printf 'g:%s' "$(bi "готов" "ready")"; return 0 ;;
                2)
                    # Замечание, которое меняет суть, — своим словом, а не
                    # общим «есть замечания».
                    if grep -q '^rule|soft|godns-beside-443|' <<<"$PF_LINES"; then printf 'y:%s' "$(bi "не на 443" "not on 443")"; return 0; fi
                    printf 'y:%s' "$(bi "готов, есть замечания" "ready, with remarks")"; return 0 ;;
            esac
            # Причину берём сразу: следующий вызов preflight перепишет PF_LINES.
            first=$(_pf_first_blocker)
        elif [ "$rc" -ne 1 ]; then
            # Скромный режим проходит там, где требовательный нет. Сказать об
            # этом в строке меню важнее, чем назвать препятствие: человек
            # иначе считает продукт вовсе неустановимым.
            printf 'y:%s %s' "$(bi "только" "only")" "$(mode_name "$m")"; return 0
        fi
        i=$((i+1))
    done
    printf 'r:%s' "$first"
}

# ── сценарии ────────────────────────────────────────────────────────────
ask_mode() {
    local id="$1" c i=0 m def defidx=1 modes=() keep=()
    read -r -a modes <<<"$(prod_mode_choices "$id")"
    [ "${#modes[@]}" -gt 0 ] || { MODE=pro; return 0; }
    # Ленивый pro — сценарий ПЕРВОЙ установки: на стоящем продукте его место
    # занимает пункт «Режим и сайт» в меню самого goAmnezia pro, а флаг
    # --lazy там ничего не делает.
    if prod_installed "$id"; then
        for m in "${modes[@]}"; do [ "$m" = lazy ] || keep+=("$m"); done
        modes=(${keep[@]+"${keep[@]}"})
    fi
    def=$(prod_mode_default "$id")
    # Второй вопрос о режиме задаст мастер продукта — но не Ленивому pro: тот
    # уходит в установщик флагом и сразу спрашивает домен.
    local again
    case " ${modes[*]} " in
        *" lazy "*) again=$(bi "Установщик продукта спросит режим ещё раз — кроме Ленивого pro: он запускается сразу." "The product installer asks the mode again — except Lazy pro, which starts straight away.") ;;
        *)          again=$(bi "Установщик продукта спросит ещё раз." "The product installer asks again.") ;;
    esac
    echo ""
    echo -e "  $(bi "Какой режим планируете? Здесь это нужно, чтобы проверить правильный набор портов." "Which mode do you plan? Here it selects the right port set to check.") ${again}"
    for m in "${modes[@]}"; do
        i=$((i+1))
        [ "$m" = "$def" ] && defidx=$i
        echo -e "  ${CYAN}${i})${NC} $(mode_name "$m") ${DIM}— $(mode_desc "$id" "$m")${NC}"
    done
    # Что значит Enter, сказано вслух: у goAmnezia pro это Lite, как у его
    # мастера, у остальных — первый пункт.
    read_line c "  $(bi "Выбор" "Choice") (Enter — ${defidx}, $(mode_name "${modes[$((defidx-1))]}")): " || return 1
    [ -z "$c" ] && c=$defidx
    # «1a» раньше доходил до `[ -ge ]` и сыпал в экран «integer expression expected».
    case "$c" in
        *[!0-9]*) warn "$(bi "Неверный ввод." "Invalid input.")"; return 1 ;;
    esac
    if [ "$c" -lt 1 ] || [ "$c" -gt "${#modes[@]}" ]; then
        warn "$(bi "Неверный ввод." "Invalid input.")"; return 1
    fi
    MODE="${modes[$((c-1))]}"
    return 0
}

# ask_ref <id> → REF. Ветку выбирает человек, а не умолчание в коде: на
# стабильной и отладочной лежат разные версии, и разница видна только здесь.
REF=""
ask_ref() {
    local id="$1" refs=() i=0 r c v inst def="" kind mark defidx=1
    read -r -a refs <<<"$(prod_refs "$id")"
    if [ "${#refs[@]}" -eq 0 ]; then REF=$(prod_ref "$id"); return 0; fi
    # Одна ветка — выбирать не из чего, но сказать какая всё равно надо.
    if [ "${#refs[@]}" -eq 1 ]; then
        REF="${refs[0]}"
        v=$(ver_cache_get "$id" "$REF") || v=""
        say "$(bi "Ветка" "Branch"): ${BOLD}${REF}${NC}${v:+ ${v}} $(kind=$(ref_kind "$REF"); [ -n "$kind" ] && printf '(%s)' "$kind") — $(bi "другой у этого продукта нет" "the product has no other")"
        return 0
    fi

    inst=$(prod_version "$id"); prod_installed "$id" || inst=""
    def=$(prod_installed_ref "$id") || def=""
    # Показываем ВСЕ ветки, а версии спрошены не у всех: добираем
    # недостающие одним заходом, чтобы в списке не было пустых строк.
    ver_fill_refs "$id"
    # Умолчание: ветка, с которой стоит, иначе первая в списке (стабильная).
    if [ -n "$def" ]; then
        local found=""
        for ((i=0; i<${#refs[@]}; i++)); do [ "${refs[$i]}" = "$def" ] && { defidx=$((i+1)); found=1; }; done
        # Стоит с ветки, которой в списке нет, — умолчанием её не называем.
        [ -n "$found" ] || def=""
    fi

    echo ""
    echo -e "  $(bi "С какой ветки ставить?" "Which branch to install from?")"
    i=0
    for r in "${refs[@]}"; do
        i=$((i+1))
        v=$(ver_cache_get "$id" "$r") || v=""
        kind=$(ref_kind "$r")
        mark=""
        if [ -n "$v" ] && [ -n "$inst" ] && ver_newer "$inst" "$v"; then
            mark=" ${GREEN}$(bi "новее установленной" "newer than installed") ${inst}${NC}"
        elif [ -n "$v" ] && [ -n "$inst" ] && [ "$v" = "$inst" ]; then
            mark=" ${DIM}$(bi "та же, что стоит" "same as installed")${NC}"
        fi
        # Версия не спрошена — так и сказать. Пустое место читается как
        # «ветки нет», а это разные вещи.
        if [ -z "$v" ]; then
            if [ "$VER_NET_OK" = "yes" ]; then v="${DIM}$(bi "не ответила" "no answer")${NC}"
            else v="${DIM}$(bi "версия не спрошена" "version not fetched")${NC}"; fi
        fi
        printf "  ${CYAN}%d)${NC} %-6s ${DIM}%s${NC}  %b%b\n" "$i" "$r" "$kind" "$v" "$mark"
    done
    [ -n "$def" ] && echo -e "  ${DIM}$(bi "Enter — оставить ту, с которой стоит" "Enter keeps the branch it is installed from"): ${refs[$((defidx-1))]}${NC}"
    read_line c || return 1
    [ -z "$c" ] && c="$defidx"
    case "$c" in
        [0-9]*) [ "$c" -ge 1 ] && [ "$c" -le "${#refs[@]}" ] || { warn "$(bi "Неверный ввод." "Invalid input.")"; return 1; }
                REF="${refs[$((c-1))]}" ;;
        *) warn "$(bi "Неверный ввод." "Invalid input.")"; return 1 ;;
    esac
    return 0
}

MODE=pro
# mode_resolve <id> — определить режим, не спрашивая, если он уже записан
# продуктом. Возвращает 1, если спросить всё-таки надо.
mode_resolve() {
    local id="$1" m
    prod_has_modes "$id" || { MODE=pro; return 0; }
    [ -z "${GOINST_ASK_MODE:-}" ] || return 1
    prod_installed "$id" || return 1
    m=$(prod_installed_mode "$id") || return 1
    MODE="$m"
    say "$(bi "Режим установленного" "Installed mode"): ${BOLD}$(mode_name "$m")${NC} — $(bi "взят из настроек продукта, спрашивать не буду" "taken from the product's own settings, not asking")"
    return 0
}

# Что будет с бесплатной версией, если поставить pro поверх. Говорится ДО
# вопросов: человек должен знать, что переживёт установку и что сменится.
free_takeover_note() {
    prod_installed "$1" && prod_free_edition "$1" >/dev/null || return 0
    echo "" >&2
    case "$1" in
    govless)
    say "$(bi "На сервере бесплатный Lite из инструкции. $(prod_name "$1") встанет поверх него: панель 3X-UI, ключи и пользователи останутся, заменится только код в /opt/govless-installer." "This server runs the free Lite from the guide. $(prod_name "$1") installs over it: the 3X-UI panel, keys and users stay, only the code in /opt/govless-installer is replaced.")"
    say "$(bi "Потом откроется меню $(prod_name "$1") в прежнем режиме Lite. Режим Pro со своим доменом и TLS включается там же: раздел VPN, смена режима." "Then the $(prod_name "$1") menu opens in the same Lite mode. Pro mode with your own domain and TLS is switched on right there: the VPN section, mode switch.")"
    ;;
    gokaskad)
    # Правила бесплатной версии идут без меток «kaskad:», и pro до 2.12 их не
    # видел: они работали мимо меню, а правило pro на том же порту вставало
    # за старым DNAT и не срабатывало. С 2.12 pro берёт их себе при запуске.
    say "$(bi "На сервере бесплатный Kaskad из инструкции: команда gokaskad сейчас открывает его. $(prod_name "$1") заменит её своей, а правила каскада бесплатной версии возьмёт себе: они продолжат работать и появятся в его меню." "This server runs the free Kaskad from the guide: the gokaskad command opens it now. $(prod_name "$1") replaces it with its own and takes over the free cascade rules: they keep working and show up in its menu.")"
    say "$(bi "Команду установки из бесплатной инструкции больше не запускайте: она вернёт бесплатную версию на место pro." "Do not run the free guide's install command again: it puts the free edition back in place of pro.")"
    ;;
    gotelegram)
    say "$(bi "Команда gotelegram сейчас открывает бесплатный MTProxy из инструкции: его запустили уже после $(prod_name "$1"), и он подменил её собой. Установщик pro вернёт свою команду, прокси pro и его настройки останутся." "The gotelegram command now opens the free MTProxy from the guide: it was run after $(prod_name "$1") and replaced the command. The pro installer restores its own command; the pro proxy and its settings stay.")"
    ;;
    esac
}

install_flow() {
    local id="$1" rc
    if osup_busy_refuse; then echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true; return 0; fi
    free_takeover_note "$id"
    if ! mode_resolve "$id"; then ask_mode "$id" || return 0; fi
    preflight "$id" "$MODE"; rc=$?
    if [ "$rc" -eq 1 ]; then
        echo ""
        if [ -n "${GOINST_FORCE:-}" ]; then
            warn "$(bi "GOINST_FORCE задан — продолжаю несмотря на препятствия." "GOINST_FORCE is set — continuing despite blockers.")"
        else
            # Мешает только ОС — порты ни при чём, к карте портов не зовём.
            [ "$PF_MUST" -gt "$PF_OSMUST" ] && say "$(bi "Карта портов: пункт «p» в главном меню." "Port map: item 'p' in the main menu.")"
            echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true
            return 0
        fi
    fi
    ask_ref "$id" || return 0
    echo ""
    local vsel; vsel=$(ver_cache_get "$id" "$REF") || vsel=""
    # Без цветов: приглашение печатает `read -p`, а он escape-последовательности
    # НЕ разворачивает — в проекте это литеральные строки для `echo -e`, и
    # человек увидел бы «\033[1mmain\033[0m» вместо жирного «main».
    local free; free=$(prod_installed "$id" && prod_free_edition "$id") || free=""
    if [ -n "$free" ]; then
        confirm "$(bi "Поставить" "Install") $(prod_name "$id") $(bi "поверх" "over") ${free} — $(bi "ветка" "branch") ${REF}${vsel:+, ${vsel}}?" y || return 0
    else
        confirm "$(bi "Запустить установщик" "Launch the installer") $(prod_name "$id") — $(bi "ветка" "branch") ${REF}${vsel:+, ${vsel}}?" y || return 0
    fi
    run_product_installer "$id"; rc=$?
    echo ""
    [ "$rc" -eq 0 ] && ok "$(bi "Установщик $(prod_name "$id") завершился." "The $(prod_name "$id") installer has finished.")"
    installer_postcheck "$id" "$REF" "$rc" || true
    shield_postcheck "$id"
    echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true
    return 0
}

# Короткий статус для `--list`: там колонок нет, только версия или прочерк.
status_line() {
    local id="$1" v free
    if prod_installed "$id"; then
        v=$(prod_version "$id")
        if free=$(prod_free_edition "$id"); then
            prod_free_shows_version "$id" || v=""
            printf "${YELLOW}[%s%s]${NC}" "$(bi "бесплатный" "free") ${free}" "${v:+ $v}"
            return 0
        fi
        printf "${GREEN}[%s%s]${NC}" "$(bi "установлен" "installed")" "${v:+ $v}"
    else
        printf "${DIM}[—]${NC}"
    fi
}

# Пункты подменю продукта. Отдельной функцией, потому что их читает не
# только экран: страж проверяет, что у каждого ключа есть ветка в
# обработчике, а мёртвый пункт и дубль номера — ошибки, которые в меню
# уже случались.
menu_items_product() {
    local id="$1" v st avail ref rv free name
    # Подменю продукта не обновляется само: там человек что-то выбирает, и
    # перерисовка под рукой только мешала бы.
    MENU_REFRESH_SEC=0; MENU_REFRESH_HOOK=""; MENU_FOOTER_INFO=""
    MENU_TITLE="$(prod_name "$id")"
    MENU_SUB="$(prod_desc "$id")"
    MENU_ITEMS=()
    MENU_W_NAME=34; MENU_W_STATUS=26; MENU_W_EXTRA=0; MENU_W_SUB=""; MENU_W_ROW=""; MENU_SVC=""
    v=$(prod_version "$id")
    if prod_installed "$id" && free=$(prod_free_edition "$id"); then
        # На месте продукта — его бесплатная версия. Её команду отсюда не
        # запускаем: человек пришёл за pro, а «Открыть меню продукта»
        # открывало ему бесплатное меню. Первый пункт ставит pro поверх.
        # Подпись не длиннее соседних: ширину окна подменю не считает, а что
        # переживёт установку, человек прочтёт в пояснении перед ней.
        case "$id" in
            govless)  avail=$(bi "ключи и пользователи останутся" "keys and users are kept") ;;
            gokaskad) avail=$(bi "правила каскада останутся" "cascade rules are kept") ;;
            gotelegram) avail=$(bi "настройки pro останутся" "pro settings are kept") ;;
            *)        avail=$(bi "штатным установщиком" "with the product's own installer") ;;
        esac
        if rv=$(prod_best_remote "$id"); then
            ref="${rv%% *}"; rv="${rv#* }"
            avail="$(bi "поставится" "will install") ${ref}: ${rv}"
        fi
        name="$(bi "Поставить" "Install") $(prod_name "$id") $(bi "поверх" "over") ${free}"
        [ "$(str_len "$name")" -gt "$MENU_W_NAME" ] && MENU_W_NAME=$(str_len "$name")
        prod_free_shows_version "$id" || v=""
        MENU_ITEMS+=("1|${name}|y:$(bi "бесплатный" "free") ${free}${v:+ $v}||${avail}")
    elif prod_installed "$id"; then
        MENU_ITEMS+=("1|$(bi "Открыть меню продукта" "Open the product menu")|g:$(bi "установлен" "installed")${v:+ $v}||$(prod_cmd "$id")")
        # У пункта обновления стоит то, ЧЕМ обновятся: без этого «обновить»
        # — предложение вслепую.
        avail=$(bi "версии с GitHub не спрошены" "versions not fetched from GitHub")
        if rv=$(prod_best_remote "$id"); then
            ref="${rv%% *}"; rv="${rv#* }"
            if ver_newer "$v" "$rv"; then avail="$(bi "в ветке" "on branch") ${ref}: ${rv}"
            else avail="$(bi "новее нет" "nothing newer")"; fi
        fi
        MENU_ITEMS+=("2|$(bi "Обновить или переустановить" "Update or reinstall")|d:${avail}||$(bi "штатным установщиком" "with the product's own installer")")
    else
        st=$(prod_readiness "$id")
        avail=""
        if rv=$(prod_best_remote "$id"); then ref="${rv%% *}"; rv="${rv#* }"; avail="$(bi "поставится" "will install") ${ref}: ${rv}"; fi
        MENU_ITEMS+=("1|$(bi "Установить" "Install")|${st}||${avail}")
    fi
    MENU_ITEMS+=("3|$(bi "Проверить порты" "Check ports")|d:||$(bi "без установки" "without installing")")
    MENU_ITEMS+=("-|||")
    MENU_ITEMS+=("0|$(bi "Назад" "Back")|d:||")
}

product_menu() {
    local id="$1" cmd
    cmd=$(prod_cmd "$id")
    while true; do
        menu_items_product "$id"
        pick_menu || return 0
        case "$PICK_KEY" in
            1)
                if prod_installed "$id" && ! prod_free_edition "$id" >/dev/null; then
                    # Меню продукта умеет обновляться — во время обновления Ubuntu нельзя.
                    if osup_busy_refuse; then echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") " >&2; read -r || true
                    elif command -v "$cmd" >/dev/null 2>&1; then "$cmd" || true
                    else warn "$(bi "Команды ${cmd} нет в PATH — запустите обновление." "Command ${cmd} is not in PATH — run the update.")"; sleep 1; fi
                else install_flow "$id"; fi ;;
            2) install_flow "$id" ;;
            3)
                if ! mode_resolve "$id"; then ask_mode "$id" || continue; fi
                preflight "$id" "$MODE" || true
                echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true ;;
            0) return 0 ;;
        esac
    done
}

# Главный экран — он же сводка: против каждого продукта либо версия, либо
# приговор проверки портов. Иначе «готов ли он к установке» узнаётся только
# заходом внутрь, а это ровно то, что оператор и хочет увидеть сразу.
# Ячейка «доступно»: что лежит в ветках и новее ли оно установленного.
prod_avail_cell() {
    local id="$1" inst="$2" rv ref v
    if ! rv=$(prod_best_remote "$id"); then printf 'd:—'; return 0; fi
    ref="${rv%% *}"; v="${rv#* }"
    if [ -n "$inst" ] && ver_newer "$inst" "$v"; then printf 'g:%s %s ↑' "$ref" "$v"
    else printf 'd:%s %s' "$ref" "$v"; fi
}

menu_items_main() {
    local i=0 n st v cols avail_w free
    MENU_TITLE="goInstaller ${GOINST_VERSION} $(bi "— установщик продуктов серии go" "— installer for the go product family")"
    # Главное меню само заново спрашивает GitHub раз в GOINST_MENU_REFRESH
    # секунд: свежий пуш должен появляться, пока экран открыт.
    MENU_REFRESH_SEC="${GOINST_MENU_REFRESH:-180}"
    case "$MENU_REFRESH_SEC" in ''|*[!0-9]*) MENU_REFRESH_SEC=0 ;; esac
    MENU_REFRESH_HOOK="menu_refresh_main"
    menu_footer_info
    MENU_SUB="$OS_PRETTY"
    MENU_ITEMS=()
    MENU_W_NAME=16; MENU_W_STATUS=22
    # Колонку «доступно» показываем, только если опрос вообще состоялся:
    # пустой столбец прочерков занимает место и ничего не сообщает.
    if [ "$VER_NET_OK" = "yes" ]; then MENU_W_EXTRA=16; else MENU_W_EXTRA=0; fi
    scan_cache_begin
    for n in "${PRODUCTS[@]}"; do
        i=$((i+1))
        v=$(prod_version "$n")
        if prod_installed "$n" && free=$(prod_free_edition "$n"); then
            prod_free_shows_version "$n" || v=""
            st="y:$(bi "бесплатный" "free") ${free}${v:+ $v}"
        elif prod_installed "$n"; then
            st="g:$(bi "установлен" "installed")${v:+ $v}"
        else
            st=$(prod_readiness "$n"); v=""
        fi
        MENU_ITEMS+=("$i|$(prod_name "$n")|$st|$(prod_avail_cell "$n" "$v")|$(prod_desc "$n")")
    done
    scan_cache_end
    MENU_ITEMS+=("-|||")
    # Обновление Ubuntu — первым из служебных: на 20.04 и 22.04 и пока идёт
    # или ждёт просмотра итог.
    osup_model
    if [ -n "$UD_OSUP" ]; then
        local ost
        case "$UD_OSUP" in
            can)  ost="g:↑ ${OSUP_TARGET}" ;;
            cont) ost="d:$(bi "контейнер" "container")" ;;
            run)  ost="y:$(bi "идёт" "running")" ;;
            fail) ost="r:✗ $(bi "прервано" "interrupted")" ;;
            done) ost="g:✓ $(bi "готово" "done")" ;;
        esac
        MENU_ITEMS+=("o|${UD_OSUPLBL}|${ost}||$(bi "обновить систему одной кнопкой; сначала — бэкап" "upgrade the system with one key; back up first")")
    fi
    MENU_ITEMS+=("p|$(bi "Карта портов" "Port map")|d:||$(bi "кто какие порты держит" "who holds which ports")")
    if [ "$VER_NET_TRIED" = "yes" ] || [ -n "$TOKEN" ]; then
        MENU_ITEMS+=("r|$(bi "Обновить сведения о версиях" "Refresh version info")|d:||$(bi "спросить GitHub заново" "ask GitHub again")")
    fi
    # Своя версия — из ветки, как у продуктов. Пункт показываем, только
    # когда в ветке действительно новее: предлагать обновление до того же
    # самого значит тратить время человека.
    local srv sref sver
    if srv=$(self_best); then
        sref="${srv%% *}"; sver="${srv#* }"
        if ver_newer "$GOINST_VERSION" "$sver"; then
            MENU_ITEMS+=("u|$(bi "Обновить goInstaller" "Update goInstaller")|g:${sver} ↑||$(bi "ветка" "branch") ${sref}, $(bi "сейчас" "now") ${GOINST_VERSION}")
        fi
    fi
    MENU_ITEMS+=("l|$(bi "Язык" "Language")|d:$(bi "русский" "English")||$(bi "сменить язык установщика" "change the installer language")")
    local cst="d:—"
    if comp_apt_ok && comp_apt_load >/dev/null 2>&1; then
        if [ "${COMP_NUP:-0}" -gt 0 ]; then cst="y:↑${COMP_NUP}"; else cst="d:$(bi "актуальны" "up to date")"; fi
    fi
    MENU_ITEMS+=("c|$(bi "Компоненты" "Components")|${cst}||$(bi "версии пакетов продуктов, обновление" "the products' package versions, updates")")
    shield_menu_line
    MENU_ITEMS+=("s|$(bi "Защита от сканеров" "Scanner protection")|${SHS_MST}||${SHS_MSUB}")
    MENU_ITEMS+=("x|$(bi "Удалить goInstaller" "Remove goInstaller")|d:||$(bi "продукты останутся" "products stay")")
    MENU_ITEMS+=("0|$(bi "Выход" "Exit")|d:||")
    # Колонки состояния и «доступно» — по самому длинному значению, не шире
    # прежних 22 и 16: с «готов» и «—» в колонках по 22 и 16 на 80 колонках
    # описаниям продуктов оставалось 14 символов.
    local it k nm a b l ws=8 we=6
    for it in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r k nm a b _ <<<"$it"
        [ "$k" = "-" ] && continue
        l=$(str_len "${a#?:}"); [ "$l" -gt "$ws" ] && ws=$l
        l=$(str_len "${b#?:}"); [ "$l" -gt "$we" ] && we=$l
    done
    [ "$ws" -le 22 ] || ws=22; [ "$we" -le 16 ] || we=16
    MENU_W_STATUS=$ws; [ "$MENU_W_EXTRA" -gt 0 ] && MENU_W_EXTRA=$we
    menu_fit_widths 16 14 '[1-9]*'
}

# Такт главного меню: спросить GitHub заново и пересобрать пункты. Вместе с
# версиями пересчитывается и готовность — порты за три минуты тоже могли
# освободиться или заняться. Вывод опроса глушит вызывающий, иначе
# «Спрашиваю GitHub…» печаталось бы поверх экрана.
menu_refresh_main() {
    versions_fetch
    self_fetch_versions
    menu_footer_info
    menu_items_main
    return 0
}

# Время под меню — время последнего опроса, а не входа в меню: раньше оно
# застывало на минуте запуска, хотя сведения обновлялись раз в три минуты.
menu_footer_info() {
    local t
    if [ "${MENU_REFRESH_SEC:-0}" -gt 0 ]; then
        MENU_FOOTER_INFO="$(bi "Сведения на" "Info as of") $(date +%H:%M), $(bi "обновляются сами раз в" "refreshed automatically every") $(( (MENU_REFRESH_SEC + 59) / 60 )) $(bi "мин" "min")"
    else
        MENU_FOOTER_INFO=""
    fi
    if t=$(gh_limited); then
        MENU_FOOTER_INFO="${MENU_FOOTER_INFO:+${MENU_FOOTER_INFO} · }$(bi "лимит GitHub исчерпан до" "GitHub limit used up until") ${t}"
    fi
    return 0
}

main_menu() {
    while true; do
        menu_items_main
        pick_menu || return 0
        case "$PICK_KEY" in
            # Цифра — номер продукта в списке. Перечислять их здесь поимённо
            # нельзя: добавление шестого продукта молча оставило бы его
            # пункт мёртвым, а таких пунктов в меню уже заводилось.
            [1-9])
                [ "$PICK_KEY" -le "${#PRODUCTS[@]}" ] && product_menu "${PRODUCTS[$((PICK_KEY-1))]}" ;;
            p) show_ports; echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true ;;
            r) versions_forget; ensure_token && { versions_fetch; self_fetch_versions; } ;;
            u) self_update; echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") "; read -r || true; return 0 ;;
            l) lang_pick "$LANG_CODE" && lang_persist ;;
            c) components_menu ;;
            s) shield_menu ;;
            o) osup_menu ;;
            x) goinst_uninstall && [ ! -e "$GOINST_BIN" ] && exit 0 ;;
            0) return 0 ;;
        esac
    done
}

# ── размер пакета: сетевая карта против пути до GitHub ──────────────────
# Хостер отдаёт виртуалке MTU 1500, а его сеть пропускает меньше (на
# 177.3.218.172 — 1452). Сервер при соединении просит пакеты по 1460 байт,
# крупный ответ GitHub с сертификатом застревает на узком месте, и TLS
# рвётся по таймауту: curl (28), то при опросе версий, то при скачивании
# установщика. Ключ при этом ни при чём, а сообщение винило его.
# Это единственное место, где goInstaller меняет систему, и только по
# ответу «1) Да»: так решил заказчик (5.10). Без согласия — лишь сказать.
NET_TARGET="${GOINST_NET_TARGET:-api.github.com}"
NET_DEV=""; NET_IFMTU=""; NET_PMTU=""; NET_IP=""

# Системные вызовы — отдельными функциями: тесты подменяют их, а не сеть.
# Все адреса, без повторов: первый из DNS может не отвечать на большие
# пакеты вовсе (20.250.119.72 для api.github.com отвечал только на 56 байт),
# и тогда по нему размер не узнать никогда.
_net_resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '!s[$1]++{print $1}'; }
_net_route_dev() { ip -4 route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
_net_if_mtu() { cat "/sys/class/net/$1/mtu" 2>/dev/null; }
# _net_ping_df <ip> <размер данных> [ожидание, с] → вывод ping; rc 0 — пакет прошёл.
_net_ping_df() { LC_ALL=C ping -4 -n -c1 -W"${3:-2}" -M do -s "$2" "$1" 2>&1; }
_net_set_mtu() { ip link set dev "$1" mtu "$2" 2>/dev/null; }

# net_mtu_pick — адрес для проверки: первый из (не больше трёх) адресов
# GitHub, ответивший на ping 1200 байт с запретом дробления. Две пробы на
# адрес: у api.github.com бывает один IPv4, и одна потерянная ICMP давала
# ложное «не отвечают» (Aeza, 2 запуска из 12). Первая удача — дальше не
# ждём; общий потолок — прежние ~6 с (GOINST_NET_PICK_MAX), когда ICMP режут
# целиком. rc 1 — не ответил ни один (NET_WHY).
net_mtu_pick() {
    local ips ip n=0 k t0=$SECONDS max="${GOINST_NET_PICK_MAX:-6}"
    NET_IP=""; NET_NIPS=0
    case "$max" in ''|*[!0-9]*) max=6 ;; esac
    ips=$(_net_resolve "$NET_TARGET")
    [ -n "$ips" ] || { NET_WHY=nodns; return 1; }
    for ip in $ips; do
        n=$(( n + 1 )); [ "$n" -le 3 ] || break
        NET_NIPS=$n
        for k in 1 2; do
            [ $(( SECONDS - t0 )) -lt "$max" ] || break 2
            if _net_ping_df "$ip" 1200 2 >/dev/null; then NET_IP="$ip"; return 0; fi
        done
    done
    NET_WHY=mute; return 1
}
# net_mtu_probe — заполняет NET_*. rc: 0 путь не уже карты, 1 уже
# (NET_PMTU), 2 узнать нельзя (причина в NET_WHY: noping, nodns, mute, lost,
# noroute, nomtu). Проверка после правки (net_mtu_apply) адрес заново не
# выбирает: пингует тот же NET_IP напрямую.
net_mtu_probe() {
    local out size lo hi m try
    NET_DEV=""; NET_IFMTU=""; NET_PMTU=""; NET_WHY=""
    command -v ping >/dev/null 2>&1 || [ -n "${GOINST_TEST:-}" ] || { NET_WHY=noping; return 2; }
    net_mtu_pick || return 2
    NET_DEV=$(_net_route_dev "$NET_IP"); [ -n "$NET_DEV" ] || { NET_WHY=noroute; return 2; }
    NET_IFMTU=$(_net_if_mtu "$NET_DEV")
    case "$NET_IFMTU" in ''|*[!0-9]*) NET_WHY=nomtu; return 2 ;; esac
    [ "$NET_IFMTU" -gt 1280 ] || return 0
    size=$((NET_IFMTU - 28))
    # Узкое место отвечает «Frag needed (mtu = N)», а повтор ядро режет само:
    # «message too long, mtu=N». Узких мест бывает несколько: на 177.3.218.172
    # первый узел называл 1472, а дальше путь сужался до 1452. Поэтому
    # спускаемся по ответам, пока пакет не пройдёт.
    local cur="$NET_IFMTU" quiet=0
    for try in 1 2 3 4 5 6 7 8; do
        if out=$(_net_ping_df "$NET_IP" $((cur - 28))); then
            [ "$cur" -lt "$NET_IFMTU" ] && { NET_PMTU="$cur"; return 1; }
            return 0
        fi
        m=$(printf '%s\n' "$out" | sed -n -E 's/.*mtu ?= ?([0-9]+).*/\1/p' | head -1)
        case "$m" in ''|*[!0-9]*) m="" ;; esac
        if [ -n "$m" ] && [ "$m" -lt "$cur" ]; then cur="$m"; quiet=0; continue; fi
        # Тот же размер ещё раз — ядро могло не успеть запомнить ответ.
        quiet=$((quiet + 1)); [ "$quiet" -ge 2 ] && break
    done
    size=$((cur - 28))
    # Ответа о размере нет — ищем сами. Не прошли и 1200 байт — ICMP режут
    # целиком, и о пути сказать нечего.
    # Адрес отвечал на 1200 при выборе, а теперь нет — ICMP теряется через раз.
    _net_ping_df "$NET_IP" 1200 >/dev/null || { NET_WHY=lost; return 2; }
    lo=1200; hi=$size
    while [ $((hi - lo)) -gt 1 ]; do
        m=$(( (lo + hi) / 2 ))
        if _net_ping_df "$NET_IP" "$m" >/dev/null; then lo=$m; else hi=$m; fi
    done
    NET_PMTU=$((lo + 28))
    [ "$NET_PMTU" -lt "$NET_IFMTU" ] && return 1
    return 0
}

# Кто настраивает карту после перезагрузки: ifupdown, netplan или неизвестно.
# netplan на 177.3.218.172 описывал enp1s0, которого нет, — поэтому ищем
# именно эту карту, а не просто наличие файлов.
net_persist_kind() {
    local dev="$1" r="${GOINST_FS_ROOT:-}" f
    if [ -r "$r/etc/network/interfaces" ] && grep -Eq "^[[:space:]]*iface[[:space:]]+${dev}[[:space:]]+inet" "$r/etc/network/interfaces"; then
        printf 'ifupdown'; return 0
    fi
    for f in "$r"/etc/netplan/*.yaml; do
        [ -r "$f" ] || continue
        grep -Eq "^[[:space:]]+${dev}:[[:space:]]*$" "$f" && { printf 'netplan'; return 0; }
    done
    printf 'none'
}

# Вписать mtu в блок карты в /etc/network/interfaces: прежнюю строку mtu
# этого блока убрать, новую поставить сразу за «iface». Резервная копия рядом.
net_persist_ifupdown() {
    local dev="$1" mtu="$2" f="${GOINST_FS_ROOT:-}/etc/network/interfaces" tmp
    cp -a "$f" "${f}.bak-goinstall-$(date +%Y%m%d%H%M%S)" 2>/dev/null || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/goinst-ifaces.XXXXXX") || return 1
    # Отступ строки mtu — как у соседних строк блока (у Aeza — 2 пробела);
    # блок пустой — 4. Без классов [[:space:]]: mawk 1.3.3 их не знает.
    awk -v dev="$dev" -v mtu="$mtu" '
        function flush(ind) { if (pend) { print (ind != "" ? ind : "    ") "mtu " mtu; pend = 0 } }
        function lead() { match($0, /^[ \t]*/); return substr($0, 1, RLENGTH) }
        /^[ \t]*(iface|auto|allow-|source|mapping)/ { flush(""); inblk = 0 }
        inblk && $1 == "mtu" { if (pend) flush(lead()); next }
        pend && /^[ \t]+[^ \t]/ { flush(lead()) }
        pend && /^[ \t]*$/ { flush("") }
        { print }
        $1 == "iface" && $2 == dev && $3 == "inet" { inblk = 1; pend = 1 }
        END { flush("") }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    local rc=$?; rm -f "$tmp"; return "$rc"
}

net_persist_netplan() {
    local dev="$1" mtu="$2"
    command -v netplan >/dev/null 2>&1 || return 1
    netplan set "ethernets.${dev}.mtu=${mtu}" >/dev/null 2>&1 || return 1
    netplan generate >/dev/null 2>&1
}

# Отказ запоминаем вместе с найденным размером: при том же — не спрашивать.
NET_DECLINE_FILE="${GOINST_NET_DECLINE_FILE:-${GOINST_DIR}/.mtu-declined}"

# net_mtu_offer [force] — проверить и, если путь уже карты, предложить
# исправление. force — спросить и после прежнего отказа (команда --net).
# Почему размер пакета узнать нельзя — словами (для --net).
net_why_text() {
    case "${NET_WHY:-}" in
        noping)  bi "нет команды ping" "there is no ping command" ;;
        nodns)   bi "адрес ${NET_TARGET} не узнать (DNS)" "cannot resolve ${NET_TARGET} (DNS)" ;;
        mute)    bi "адреса GitHub (${NET_NIPS:-0}) не отвечают на ping нужного размера — 1200 байт с запретом дробления; ICMP, видимо, режется по пути" "the GitHub addresses (${NET_NIPS:-0}) do not answer a ping of the needed size — 1200 bytes, do-not-fragment; ICMP is probably filtered on the way" ;;
        lost)    bi "адрес GitHub ${NET_IP:-?} ответил на ping 1200 байт, а при поиске размера перестал — ICMP теряется через раз, размер не узнать" "the GitHub address ${NET_IP:-?} answered a 1200-byte ping, then stopped while the size was being searched — ICMP is lost now and then, the size cannot be found" ;;
        noroute) bi "нет маршрута до ${NET_IP:-GitHub}" "no route to ${NET_IP:-GitHub}" ;;
        nomtu)   bi "размер пакета карты ${NET_DEV:-?} не прочитать" "cannot read the packet size of ${NET_DEV:-?}" ;;
        *)       bi "причина неизвестна" "unknown reason" ;;
    esac
}
net_mtu_offer() {
    local force="${1:-}" rc kind
    # Во время обновления Ubuntu сеть не трогаем: правка пишет netplan или
    # interfaces, а их как раз меняет апгрейдер.
    if osup_busy; then [ -n "$force" ] && { err "$(osup_busy_text)"; return 1; }; return 0; fi
    # Набор тестов настоящую сеть не трогает, кроме тех проверок, что
    # подменяют системные вызовы и включают GOINST_NET_TEST.
    if [ -n "${GOINST_TEST:-}" ] && [ -z "${GOINST_NET_TEST:-}" ]; then return 0; fi
    [ -n "${GOINST_NO_NET:-}" ] && [ -z "$force" ] && return 0
    net_mtu_probe; rc=$?
    if [ "$rc" -eq 0 ]; then
        [ -n "$force" ] && ok "$(bi "Размер пакета в порядке: ${NET_DEV:-?} — ${NET_IFMTU:-?}, путь до GitHub его пропускает." "Packet size is fine: ${NET_DEV:-?} is ${NET_IFMTU:-?}, the path to GitHub carries it.")"
        return 0
    fi
    if [ "$rc" -eq 2 ]; then
        [ -n "$force" ] && warn "$(bi "Проверить размер пакета не вышло:" "Could not check the packet size:") $(net_why_text)."
        return 0
    fi
    if [ -z "$force" ] && [ "$(cat "$NET_DECLINE_FILE" 2>/dev/null)" = "${NET_DEV}:${NET_PMTU}" ]; then return 0; fi
    # Без терминала спросить некого: только сказать. Конец ввода — не «нет»,
    # отказ из него не записываем.
    local asking=1
    [ -t 0 ] || [ -n "${GOINST_NET_TEST:-}" ] || asking=0
    echo "" >&2
    warn "$(bi "Сетевая карта ${NET_DEV} настроена на пакеты в ${NET_IFMTU} байт, а путь до GitHub пропускает только ${NET_PMTU}. Из-за этого соединения с GitHub могут рваться: «SSL connection timeout» при опросе версий и при скачивании установщиков. Ключ тут ни при чём." "Network card ${NET_DEV} is set to ${NET_IFMTU}-byte packets, but the path to GitHub carries only ${NET_PMTU}. Because of that GitHub connections may break: «SSL connection timeout» while checking versions and downloading installers. The key is not at fault.")"
    kind=$(net_persist_kind "$NET_DEV")
    case "$kind" in
        ifupdown) say "$(bi "Исправление: размер ${NET_PMTU} для ${NET_DEV} сейчас и запись в /etc/network/interfaces (с копией рядом) — чтобы пережило перезагрузку." "Fix: size ${NET_PMTU} for ${NET_DEV} now, plus a line in /etc/network/interfaces (backed up) so it survives a reboot.")" ;;
        netplan)  say "$(bi "Исправление: размер ${NET_PMTU} для ${NET_DEV} сейчас и в настройках netplan — чтобы пережило перезагрузку." "Fix: size ${NET_PMTU} for ${NET_DEV} now and in the netplan settings so it survives a reboot.")" ;;
        *)        say "$(bi "Исправление: размер ${NET_PMTU} для ${NET_DEV} сейчас. Где сеть настраивается после перезагрузки, не нашёл — закрепить придётся вручную." "Fix: size ${NET_PMTU} for ${NET_DEV} now. I did not find where the network is configured at boot, so making it permanent is manual.")" ;;
    esac
    if [ "$asking" -eq 0 ]; then
        say "$(bi "Исправить: goinstall --net, или вручную ip link set dev ${NET_DEV} mtu ${NET_PMTU}." "To fix: goinstall --net, or by hand ip link set dev ${NET_DEV} mtu ${NET_PMTU}.")"
        return 0
    fi
    if ! confirm "$(bi "Изменить размер пакета сетевой карты ${NET_DEV} на ${NET_PMTU}?" "Change the packet size of network card ${NET_DEV} to ${NET_PMTU}?")" y; then
        mkdir -p "$(dirname "$NET_DECLINE_FILE")" 2>/dev/null && printf '%s\n' "${NET_DEV}:${NET_PMTU}" > "$NET_DECLINE_FILE" 2>/dev/null
        say "$(bi "Оставил как есть. Вручную: ip link set dev ${NET_DEV} mtu ${NET_PMTU}. Спросить снова: goinstall --net" "Left as is. By hand: ip link set dev ${NET_DEV} mtu ${NET_PMTU}. Ask again: goinstall --net")"
        return 0
    fi
    # Правили (или откатили) — итог надо дать прочитать до «Аркады» (NET_CHANGED).
    NET_CHANGED=1
    net_mtu_apply "$kind"
}

net_mtu_apply() {
    local kind="$1" dev="$NET_DEV" mtu="$NET_PMTU" old="$NET_IFMTU" rc try
    if ! _net_set_mtu "$dev" "$mtu"; then
        err "$(bi "Не удалось поменять размер пакета ${dev}." "Could not change the packet size of ${dev}.")"; return 1
    fi
    # Проверяем делом: после правки полный пакет должен проходить до ТОГО ЖЕ
    # адреса, по которому размер нашли (новый выбор адреса мог дать
    # «немой» узел и ложный откат). Две попытки: одна потеря пакета правку
    # не откатывает. Не прошёл — вернуть как было: записывать непроверенное
    # в настройки нельзя.
    rc=1
    for try in 1 2; do _net_ping_df "$NET_IP" $(( mtu - 28 )) >/dev/null && { rc=0; break; }; done
    if [ "$rc" -ne 0 ]; then
        _net_set_mtu "$dev" "$old"
        err "$(bi "После правки полный пакет (${mtu}) до GitHub (${NET_IP}) не проходит — вернул ${old}, ничего не записал." "After the change a full packet (${mtu}) still does not reach GitHub (${NET_IP}) — restored ${old}, wrote nothing.")"
        return 1
    fi
    ok "$(bi "Размер пакета ${dev}: ${mtu}." "Packet size of ${dev}: ${mtu}.")"
    case "$kind" in
        ifupdown)
            if net_persist_ifupdown "$dev" "$mtu"; then ok "$(bi "Записано в /etc/network/interfaces, копия рядом." "Written to /etc/network/interfaces, a backup is next to it.")"
            else warn "$(bi "Записать в /etc/network/interfaces не удалось: после перезагрузки вернётся ${old}." "Could not write /etc/network/interfaces: ${old} comes back after a reboot.")"; fi ;;
        netplan)
            if net_persist_netplan "$dev" "$mtu"; then ok "$(bi "Записано в настройки netplan." "Written to the netplan settings.")"
            else warn "$(bi "Записать в netplan не удалось: после перезагрузки вернётся ${old}." "Could not write to netplan: ${old} comes back after a reboot.")"; fi ;;
        *)  warn "$(bi "Действует до перезагрузки. Закрепите mtu ${mtu} для ${dev} в настройках сети сервера." "Active until reboot. Make mtu ${mtu} for ${dev} permanent in the server's network settings.")" ;;
    esac
    rm -f "$NET_DECLINE_FILE" 2>/dev/null
    return 0
}

# ── удаление самого goInstaller ─────────────────────────────────────────
# Уносит только своё: команды goinstall и go-installer, каталог
# /opt/go-installer (ключ, кеш версий, язык, размер меню), таймер сводки и
# скрипт входа, защиту от сканеров (таблица nft, таймер, списки). Продукты,
# их команды и настройки не трогает. Размер пакета
# сетевой карты (если его меняли через --net) остаётся: это настройка сети,
# и без неё вернутся обрывы до GitHub.
# Ключ — по выбору: его как запасной читает goKaskad pro, когда качает ядро
# AmneziaWG, и его же подхватит goInstaller, если поставить заново.
goinst_remove_list() {  # что именно уйдёт — для показа
    local f
    for f in "$GOINST_BIN" "$GOINST_BIN_ALIAS"; do [ -e "$f" ] || [ -L "$f" ] && printf '%s\n' "$f"; done
    [ -d "$GOINST_DIR" ] && printf '%s\n' "$GOINST_DIR"
    _osup_paths
    for f in "$SUM_UNIT_DIR/goinstall-watch.timer" "$SUM_UNIT_DIR/goinstall-watch.service" "$SUM_HOOK" "$OSUP_HOOK" "$OSUP_UNITF"; do [ -e "$f" ] && printf '%s\n' "$f"; done
    _shield_paths
    for f in "$SHIELD_UNITD/$SHIELD_UNIT.timer" "$SHIELD_UNITD/$SHIELD_UNIT.path" "$SHIELD_UNITD/$SHIELD_UNIT.service"; do [ -e "$f" ] && printf '%s\n' "$f"; done
    case "$SHIELD_DIR" in "$GOINST_DIR"/*) ;; *) [ -d "$SHIELD_DIR" ] && printf '%s\n' "$SHIELD_DIR" ;; esac
    return 0
}

# goinst_remove <keep|drop> — сделать, без вопросов. rc 1 — каталог странный.
goinst_remove() {
    local key="$1" f
    osup_busy_refuse && return 1
    # Страховка от пустой или подменённой переменной: rm -rf «/» недопустим.
    case "$GOINST_DIR" in
        /*/*|/opt/go-installer) ;;
        *) err "$(bi "Каталог goInstaller задан странно (${GOINST_DIR:-пусто}) — ничего не удаляю." "The goInstaller directory looks wrong (${GOINST_DIR:-empty}) — removing nothing.")"; return 1 ;;
    esac
    if command -v systemctl >/dev/null 2>&1 && [ -e "$SUM_UNIT_DIR/goinstall-watch.timer" ]; then
        systemctl disable --now goinstall-watch.timer >/dev/null 2>&1 || true
    fi
    rm -f "$SUM_UNIT_DIR/goinstall-watch.service" "$SUM_UNIT_DIR/goinstall-watch.timer" "$SUM_HOOK" 2>/dev/null
    # Защита от сканеров: таймер, служба и своя таблица nft — до каталога,
    # иначе таймер звал бы удалённую команду. Таблица не снялась — сказать.
    shield_teardown || warn "$(bi "Таблицу nft защиты от сканеров снять не вышло: nft delete table inet ${SHIELD_TABLE}" "Could not remove the scanner protection nft table: nft delete table inet ${SHIELD_TABLE}")"
    case "$SHIELD_DIR" in "$GOINST_DIR"/*) ;; /*/*) rm -rf "$SHIELD_DIR" ;; esac
    # Следы прерванного обновления Ubuntu: скрипт входа, служба, apt.conf.d.
    _osup_paths; rm -f "$OSUP_HOOK" 2>/dev/null
    { [ -e "$OSUP_UNITF" ] || [ -e "$OSUP_APTCONF" ]; } && osup_cleanup
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    # Псевдоним — только если это наш: ссылка на goinstall или наш скрипт.
    if [ -L "$GOINST_BIN_ALIAS" ]; then rm -f "$GOINST_BIN_ALIAS"
    elif grep -q '^GOINST_VERSION=' "$GOINST_BIN_ALIAS" 2>/dev/null; then rm -f "$GOINST_BIN_ALIAS"; fi
    if [ -e "$GOINST_BIN" ] && ! grep -q '^GOINST_VERSION=' "$GOINST_BIN" 2>/dev/null; then
        warn "$(bi "${GOINST_BIN} — не goInstaller, оставляю." "${GOINST_BIN} is not goInstaller, leaving it.")"
    else
        rm -f "$GOINST_BIN"
    fi
    if [ "$key" = keep ] && [ -f "$TOKEN_FILE" ]; then
        for f in "$GOINST_DIR"/* "$GOINST_DIR"/.[!.]*; do
            [ -e "$f" ] || continue
            [ "$f" = "$TOKEN_FILE" ] && continue
            rm -rf "$f"
        done
    else
        rm -rf "$GOINST_DIR"
    fi
    return 0
}

goinst_remove_done() {  # goinst_remove_done <keep|drop>
    ok "$(bi "goInstaller удалён. Продукты на месте, их команды работают." "goInstaller is removed. The products stay, their commands work.")"
    [ "$1" = keep ] && [ -f "$TOKEN_FILE" ] && say "$(bi "Ключ оставлен: ${TOKEN_FILE}." "The key is kept: ${TOKEN_FILE}.")"
    say "$(bi "Поставить снова — той же командой из клуба, что и в первый раз." "To install again, use the same club command as the first time.")"
}

# goinst_uninstall [--yes] [--keep-key|--drop-key] — команда --uninstall.
goinst_uninstall() {
    local yes="" key="" a list
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            --keep-key) key=keep ;;
            --drop-key) key=drop ;;
            *) usage; return 64 ;;
        esac
    done
    osup_busy_refuse && return 1
    list=$(goinst_remove_list)
    if [ -z "$list" ]; then ok "$(bi "goInstaller на этом сервере уже не стоит." "goInstaller is not installed on this server.")"; return 0; fi
    # Без терминала спросить некого — отказ до любых вопросов, а не немой
    # выход на первом же чтении.
    if [ -z "$yes" ] && [ ! -t 0 ]; then
        err "$(bi "Без терминала спросить некого: goinstall --uninstall --yes" "No terminal to ask: goinstall --uninstall --yes")"
        return 3
    fi
    print_header "$(bi "Удаление goInstaller" "Removing goInstaller")"
    say "$(bi "Будет удалено:" "Will be removed:")"
    printf '      %s\n' $list >&2
    if shield_installed; then say "$(bi "Защита от сканеров снимется вместе с ним: правила nft, таймер, списки, статистика." "Scanner protection goes with it: the nft rules, the timer, the lists, the statistics.")"
    elif _shield_has_stats; then say "$(bi "Статистика защиты от сканеров удалится вместе с ним." "Scanner protection statistics go with it.")"; fi
    say "$(bi "Не тронется: продукты, их команды и настройки; размер пакета сетевой карты." "Untouched: the products, their commands and settings; the network card packet size.")"
    if [ -z "$key" ] && [ -f "$TOKEN_FILE" ]; then
        if [ -n "$yes" ]; then key=drop
        else
            echo "" >&2
            echo -e "  $(bi "Ключ доступа клуба лежит в ${TOKEN_FILE}. goKaskad pro берёт его как запасной, а goInstaller подхватит, если поставить заново." "The club access key is in ${TOKEN_FILE}. goKaskad pro uses it as a fallback, and goInstaller picks it up if installed again.")" >&2
            echo -e "  ${CYAN}1)${NC} $(bi "Удалить и ключ" "Remove the key too") ${DIM}— $(bi "по умолчанию" "default")${NC}" >&2
            echo -e "  ${CYAN}2)${NC} $(bi "Ключ оставить" "Keep the key")" >&2
            read_line a || return 1
            case "${a:-1}" in 1) key=drop ;; 2) key=keep ;; *) warn "$(bi "Неверный ввод." "Invalid input.")"; return 1 ;; esac
        fi
    fi
    [ -n "$key" ] || key=drop
    if [ -z "$yes" ]; then
        confirm "$(bi "Удалить goInstaller?" "Remove goInstaller?")" n || { say "$(bi "Отменено, ничего не удалено." "Cancelled, nothing removed.")"; return 0; }
    fi
    goinst_remove "$key" || return 1
    goinst_remove_done "$key"
    return 0
}

usage() {
    local p modes_line=""
    for p in "${PRODUCTS[@]}"; do
        prod_has_modes "$p" && modes_line="${modes_line:+${modes_line}; }${p} — $(prod_mode_choices "$p")"
    done
    cat <<USAGE
goInstaller ${GOINST_VERSION}

  goinstall                       $(bi "меню" "menu")
  goinstall --list                $(bi "что установлено" "what is installed")
  goinstall --ports               $(bi "кто какие порты держит" "who holds which ports")
  goinstall --versions            $(bi "версии на сервере и в ветках GitHub" "versions on this server and on GitHub branches")
  goinstall --self-update [$(bi "ветка" "branch")]
                                  $(bi "обновить сам goInstaller" "update goInstaller itself")
  goinstall --key [set|check|forget]
                                  $(bi "ключ доступа: ввести, проверить, удалить" "access key: set, check, remove")
  goinstall --check <id> [$(bi "режим" "mode")]
                                  $(bi "проверка портов без установки; код: 0 ок, 1 препятствия, 2 замечания" "port check without installing; rc: 0 ok, 1 blockers, 2 remarks")
  goinstall --install <id> [$(bi "режим" "mode")] [$(bi "ветка" "branch")]
                                  $(bi "сразу к установке; без ветки спросит; без режимов — сразу ветка: --install gokaskad dev; код — установщика, 1 — продукт не встал или остался бесплатный" "straight to installing; asks for the branch if omitted; no modes — branch right away: --install gokaskad dev; rc — the installer's, 1 — the product did not install or the free edition stayed")
  goinstall --uninstall [--yes] [--keep-key]
                                  $(bi "удалить сам goInstaller; продукты не трогает; код 3 — без терминала и без --yes" "remove goInstaller itself; products are untouched; rc 3 — no terminal and no --yes")
  goinstall --net                 $(bi "проверить размер пакета до GitHub и предложить исправление" "check the packet size to GitHub and offer a fix")
  goinstall --components [refresh] $(bi "системные пакеты продуктов: что стоит и что доступно; refresh — сначала apt-get update" "the products' system packages: installed and available; refresh — apt-get update first")
  goinstall --components update <id…|all> [--yes]
                                  $(bi "обновить пакеты apt компонентов; код: 0 обновлено, 1 ошибка apt, 2 обновлять нечего, 3 без терминала и без --yes" "upgrade the components' apt packages; rc: 0 updated, 1 apt error, 2 nothing to update, 3 no terminal and no --yes")
  goinstall --os-upgrade [--yes]  $(bi "обновить Ubuntu 20.04/22.04 до 24.04: проверка, предупреждение о бэкапе, запуск службой; код: 0 запущено, 1 отказ, 2 ответ «нет», 3 уже идёт, 4 без терминала и без --yes" "upgrade Ubuntu 20.04/22.04 to 24.04: check, backup warning, start as a service; rc: 0 started, 1 refused, 2 answered “no”, 3 already running, 4 no terminal and no --yes")
  goinstall --os-upgrade status   $(bi "ход и итог; код: 0 нет или готово, 1 прервано, 3 идёт" "progress and result; rc: 0 none or done, 1 interrupted, 3 running")
  goinstall --os-upgrade dismiss  $(bi "снять отметку «прервано» — обновлять не буду (журнал остаётся)" "clear the “interrupted” mark — not upgrading (the log stays)")
  goinstall --summary on|off       $(bi "сводка при входе по SSH и опрос раз в 30 минут" "login summary over SSH and polling every 30 minutes")
  goinstall --shield [status|check|update|on|off|vk on|vk off|remove] [--yes]
                                  $(bi "защита от сканеров и ботов (списки AS_Network_List); код: 0 работает, 1 не работает, 3 не стоит; off и remove без терминала — только с --yes, иначе 64" "scanner and bot protection (AS_Network_List lists); rc: 0 working, 1 not working, 3 not installed; off and remove without a terminal need --yes, otherwise 64")
  goinstall --shield stats [24h|7d|30d|all] | stats top [24h|7d|30d|all] | stats size | stats reset [--yes]
                                  $(bi "статистика защиты: сканеры на входе и соединения к ВК на выходе; код 3 — статистики нет; reset без терминала — только с --yes, иначе 64" "protection statistics: scanners on the way in and connections to VK on the way out; rc 3 — no statistics; reset without a terminal needs --yes, otherwise 64")
  goinstall --version

  id: ${PRODUCTS[*]}
  $(bi "режимы" "modes"): ${modes_line}

  $(bi "Окружение" "Environment"): GH_TOKEN, GOINST_SRC_<id>, GOINST_REF_<id>, GOINST_REPO_<id>, GOWARP_KEY, GOINST_LANG=ru|en,
    GOINST_LAZY_DOMAIN, GOINST_LAZY_KEYS ($(bi "Ленивый pro у goamnezia" "Lazy pro of goamnezia"))
USAGE
}

valid_id() { local p; for p in "${PRODUCTS[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

list_products() {
    local n
    for n in "${PRODUCTS[@]}"; do
        printf "  %-16s %s\n" "$(prod_name "$n")" "$(status_line "$n")"
    done
}

# Таблица версий: что стоит на сервере и что лежит в каждой ветке.
show_versions() {
    local n ref v inst cell shown free
    versions_fetch
    self_fetch_versions
    print_header "$(bi "Версии: на сервере и в ветках" "Versions: on this server and on the branches")"
    if [ -z "$TOKEN" ] && [ -z "${GOINST_NO_NET:-}" ]; then
        warn "$(bi "Ветки не опрошены: нет ключа. Задайте GH_TOKEN." "Branches not queried: no key. Set GH_TOKEN.")"
    fi
    # Колонки через pad_to: `printf '%-16s'` считает БАЙТЫ, и «goTelegram pro»
    # рядом с «goДНС» разъехалось бы на длину кириллицы.
    printf "  ${DIM}%s %s %s${NC}\n" "$(pad_to "$(bi "продукт" "product")" 16)" \
        "$(pad_to "$(bi "на сервере" "on server")" 12)" "$(bi "в ветках" "on branches")" >&2
    cell=""
    for ref in $(self_refs); do
        v=$(ver_cache_get "$SELF_ID" "$ref") || v=""
        [ -n "$v" ] || continue
        if ver_newer "$GOINST_VERSION" "$v"; then cell+="${ref} ${v} ↑  "; else cell+="${ref} ${v}  "; fi
    done
    printf "  %s %s %s\n" "$(pad_to "goInstaller" 16)" "$(pad_to "$GOINST_VERSION" 12)" "${cell:-—}" >&2
    for n in "${PRODUCTS[@]}"; do
        inst=$(prod_version "$n")
        prod_installed "$n" || inst=""
        shown="${inst:-—}"
        if prod_installed "$n" && free=$(prod_free_edition "$n"); then
            shown="$free"; prod_free_shows_version "$n" && shown="${free}${inst:+ $inst}"
        fi
        cell=""
        for ref in $(prod_refs "$n"); do
            v=$(ver_cache_get "$n" "$ref") || v=""
            [ -n "$v" ] || continue
            if [ -n "$inst" ] && ver_newer "$inst" "$v"; then cell+="${ref} ${v} ↑  "
            else cell+="${ref} ${v}  "; fi
        done
        printf "  %s %s %s\n" "$(pad_to "$(prod_name "$n")" 16)" "$(pad_to "$shown" 12)" "${cell:-—}" >&2
    done
    echo "" >&2
}

# ── компоненты: системные пакеты продуктов ──────────────────────────────
# Решение заказчика 14.10: экран «Компоненты» показывает версии системных
# компонентов, нужных продуктам, — что стоит и что доступно, — и обновляет
# отмеченные или все. Сам goInstaller обновляет ТОЛЬКО пакеты apt, и только
# по выбору человека и подтверждению цифрой: это второе исключение из
# правила «ничего не настраивает» после размера пакета. Движки продуктов
# (3X-UI, Xray, telemt, образы и модуль AmneziaWG, xray прокси API Telegram,
# accel-ppp, acme.sh, окружения ботов) — только показ: версия и кто их
# обновляет. Обновление в обход продукта ломает совместимость.
#
# Таблица ОДНА, её читают «Аркада», нумерованное меню, --components и тесты.
# comp_spec <id> → «главные пакеты|ещё пакеты группы|продукты». Главных
# несколько — берётся первый стоящий. «@py» — python3.X, на который указывает
# /usr/bin/python3; «*» в продуктах — все. Шаблоны вроде libnginx-mod-* —
# по установленным пакетам.
COMP_IDS=(nginx certbot docker python3 dnsdist warp cloudflared firewall nftables wireguard strongswan ocserv openvpn tools)
comp_spec() {
    case "$1" in
        nginx)       printf 'nginx|nginx-common nginx-core nginx-full nginx-light libnginx-mod-*|govless gotelegram goamnezia gokaskad' ;;
        certbot)     printf 'certbot|python3-certbot python3-certbot-nginx python3-acme|govless gotelegram godns goamnezia gokaskad' ;;
        docker)      printf 'docker.io docker-ce|docker-ce-cli containerd containerd.io runc|goamnezia gowarp' ;;
        python3)     printf '@py|python3 python3-minimal libpython3-stdlib @py-minimal lib@py-stdlib lib@py-minimal @py-venv python3-venv|govless gotelegram godns gokaskad goamnezia' ;;
        dnsdist)     printf 'dnsdist||godns' ;;
        warp)        printf 'cloudflare-warp||gowarp' ;;
        cloudflared) printf 'cloudflared||govless' ;;
        firewall)    printf 'iptables|iptables-persistent netfilter-persistent|gokaskad gotelegram goamnezia' ;;
        nftables)    printf 'nftables||gokaskad' ;;
        wireguard)   printf 'wireguard-tools||gokaskad gotelegram' ;;
        strongswan)  printf 'strongswan-swanctl strongswan|charon-systemd strongswan-* libcharon-* libstrongswan*|gokaskad' ;;
        ocserv)      printf 'ocserv||gokaskad' ;;
        openvpn)     printf 'openvpn||gokaskad' ;;
        tools)       printf '|curl git jq openssl sqlite3 qrencode socat ca-certificates|*' ;;
        *) return 1 ;;
    esac
}
comp_valid() { comp_spec "$1" >/dev/null; }
# Подписи: что это и что будет при обновлении (столбцы таблицы спецификации).
comp_what() {
    case "$1" in
        nginx)       bi "веб-сервер: сайт-маска, проверка сертификатов" "web server: mask site, certificate checks" ;;
        certbot)     bi "сертификаты Let's Encrypt" "Let's Encrypt certificates" ;;
        docker)      bi "Docker: контейнеры AmneziaWG" "Docker: AmneziaWG containers" ;;
        python3)     bi "python для ботов и панелей" "python for the bots and panels" ;;
        dnsdist)     bi "DNS-движок goDNS pro (репозиторий PowerDNS, линия 2.0)" "goDNS pro DNS engine (PowerDNS repository, 2.0 line)" ;;
        warp)        bi "клиент Cloudflare WARP" "Cloudflare WARP client" ;;
        cloudflared) bi "туннель Cloudflare для бота в режиме Lite" "Cloudflare tunnel for the bot in Lite mode" ;;
        firewall)    bi "правила iptables и их сохранение" "iptables rules and saving them" ;;
        nftables)    bi "правила nftables (goKaskad pro 3 на 24.04)" "nftables rules (goKaskad pro 3 on 24.04)" ;;
        wireguard)   bi "WireGuard" "WireGuard" ;;
        strongswan)  bi "шлюз goKaskad pro 3: IKEv2, L2TP/IPsec" "goKaskad pro 3 gateway: IKEv2, L2TP/IPsec" ;;
        ocserv)      bi "шлюз goKaskad pro 3: OpenConnect" "goKaskad pro 3 gateway: OpenConnect" ;;
        openvpn)     bi "шлюз goKaskad pro 3: OpenVPN" "goKaskad pro 3 gateway: OpenVPN" ;;
        tools)       bi "базовые утилиты продуктов" "the products' basic tools" ;;
    esac
}
comp_note() {
    case "$1" in
        nginx)   bi "nginx перезапустится: сайт и проверка сертификатов прервутся на секунды" "nginx restarts: the site and certificate checks pause for seconds" ;;
        docker)  bi "новая версия заработает после перезапуска docker или сервера; при перезапуске контейнеры переподключатся" "the new version runs after docker or the server restarts; the containers reconnect then" ;;
        dnsdist) bi "dnsdist перезапустится" "dnsdist restarts" ;;
        warp)    bi "warp-svc перезапустится" "warp-svc restarts" ;;
    esac
}
comp_title() {  # comp_title <id> [python3.X] — имя строки
    case "$1" in
        docker) printf 'Docker' ;; warp) printf 'Cloudflare WARP' ;; firewall) printf 'iptables' ;;
        wireguard) printf 'WireGuard' ;; strongswan) printf 'strongSwan' ;; openvpn) printf 'OpenVPN' ;;
        python3) if [ -n "${2:-}" ]; then printf 'python %s' "${2#python}"; else printf 'python3'; fi ;;
        tools) bi "утилиты" "tools" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Есть ли с чем работать. В тестах (GOINST_TEST) apt настоящий не трогаем:
# GOINST_APT_OK=1 включает его вместе с заглушками в PATH.
comp_apt_ok() {
    [ -n "${GOINST_APT_OK:-}" ] && return 0
    [ -z "${GOINST_TEST:-}" ] && command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1
}
# Системные вызовы — по одному на все пакеты, а не на пакет.
_comp_dpkg()   { dpkg-query -W -f='${Package}|${Version}|${source:Package}|${db:Status-Abbrev}\n' 2>/dev/null; }
_comp_policy() { LC_ALL=C apt-cache policy "$@" 2>/dev/null; }
_comp_holds()  { apt-mark showhold 2>/dev/null; }
_comp_t() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
# _deb_newer <стоит> <кандидат> — кандидат новее. dpkg сравнивает по правилам
# Debian; без него (тесты на macOS) — просто «другая версия».
_deb_newer() {
    [ -n "$2" ] && [ "$2" != "(none)" ] && [ "$1" != "$2" ] || return 1
    if command -v dpkg >/dev/null 2>&1; then dpkg --compare-versions "$2" gt "$1"; return $?; fi
    return 0
}
# python3.X, на который указывает /usr/bin/python3: им же построены окружения ботов.
comp_py_name() {
    local r="${GOINST_FS_ROOT:-}" l
    l=$(readlink "$r/usr/bin/python3" 2>/dev/null) || l=""
    l="${l##*/}"
    case "$l" in python3.[0-9]*) printf '%s' "$l"; return 0 ;; esac
    if [ -z "$r" ] && l=$(python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])' 2>/dev/null); then printf '%s' "$l"; return 0; fi
    return 1
}
# Продукты строки: сначала стоящие; не стоит ни один — весь список, приглушённо
# (COMP_PRODM=1).
comp_prods() {  # comp_prods <продукты таблицы> → COMP_PRODS, COMP_PRODM
    local list="$1" id out="" all=""
    [ "$list" = "*" ] && list="${PRODUCTS[*]}"
    COMP_PRODM=0
    for id in $list; do
        all+="${all:+, }$(prod_name "$id")"
        case "${COMP_INST:- }" in *" $id "*) out+="${out:+, }$(prod_name "$id")" ;; esac
    done
    if [ -z "$out" ]; then out="$all"; COMP_PRODM=1; fi
    COMP_PRODS="$out"
}

# Свежесть списков apt — время последней удачной проверки: самое позднее из
# update-success-stamp (apt-daily), своей отметки удачного comp_refresh и
# pkgcache.bin. mtime *Release — это время публикации на зеркале (apt ставит
# файлам время сервера): «от 15:13» не менялось и после «r». Только если
# ничего этого нет — по *Release, как раньше. Списков нет — «не скачаны».
COMP_LISTS_T=0
comp_ok_file() { printf '%s/.apt-ok' "$GOINST_DIR"; }
comp_lists_age() {
    local d="${GOINST_APT_LISTS:-${GOINST_FS_ROOT:-}/var/lib/apt/lists}" r="${GOINST_FS_ROOT:-}" t f=() g=()
    COMP_LISTS_T=0
    for t in "$d"/*Release; do [ -e "$t" ] && f+=("$t"); done
    [ "${#f[@]}" -gt 0 ] || return 0
    for t in "${GOINST_APT_STAMP:-$r/var/lib/apt/periodic/update-success-stamp}" "${GOINST_APT_PKGCACHE:-$r/var/cache/apt/pkgcache.bin}"; do [ -e "$t" ] && g+=("$t"); done
    t=$(head -1 "$(comp_ok_file)" 2>/dev/null) || t=""
    case "$t" in ''|*[!0-9]*) ;; *) COMP_LISTS_T="$t" ;; esac
    if [ "${#g[@]}" -gt 0 ]; then
        while read -r t; do
            case "$t" in ''|*[!0-9]*) continue ;; esac
            [ "$t" -gt "$COMP_LISTS_T" ] && COMP_LISTS_T="$t"
        done < <(stat -c %Y "${g[@]}" 2>/dev/null || stat -f %m "${g[@]}" 2>/dev/null)
    fi
    [ "$COMP_LISTS_T" -gt 0 ] && return 0
    while read -r t; do
        case "$t" in ''|*[!0-9]*) continue ;; esac
        [ "$t" -gt "$COMP_LISTS_T" ] && COMP_LISTS_T="$t"
    done < <(stat -c %Y "${f[@]}" 2>/dev/null || stat -f %m "${f[@]}" 2>/dev/null)
    return 0
}
# «ЧЧ:ММ» за последние сутки, иначе «ДД.ММ»; списков нет — пусто.
comp_lists_when() {
    local now
    [ "$COMP_LISTS_T" -gt 0 ] || { COMP_LISTS_TXT=""; return 0; }
    printf -v now '%(%s)T' -1
    if [ $(( now - COMP_LISTS_T )) -lt 86400 ]; then printf -v COMP_LISTS_TXT '%(%H:%M)T' "$COMP_LISTS_T"
    else printf -v COMP_LISTS_TXT '%(%d.%m)T' "$COMP_LISTS_T"; fi
}
# Подпись свежести: «списки apt от 14:05» / «списки apt не скачаны».
comp_lists_label() {
    if [ -n "${COMP_LISTS_TXT:-}" ]; then printf '%s %s' "$(bi "списки apt от" "apt lists as of")" "$COMP_LISTS_TXT"
    else bi "списки apt не скачаны" "apt lists not downloaded"; fi
}
# Списки старше GOINST_APT_MAXAGE (12 часов) или их нет — пора проверить.
comp_lists_stale() {
    local now max="${GOINST_APT_MAXAGE:-43200}"
    case "$max" in ''|*[!0-9]*) max=43200 ;; esac
    [ "$COMP_LISTS_T" -gt 0 ] || return 0
    printf -v now '%(%s)T' -1
    [ $(( now - COMP_LISTS_T )) -gt "$max" ]
}

# comp_apt_load — строки компонентов apt. Массивы по строкам:
# CA_ID, CA_NAME, CA_MAIN (главный пакет), CA_VER (его версия), CA_CAND
# (его кандидат, если новее), CA_UP («пакет=кандидат …» к обновлению, без
# закреплённых), CA_HOLD (закреплённые пакеты группы), CA_N (пакетов в
# группе), CA_UPN (сколько из них обновится вместе с роднёй), CA_PROD/CA_PRODM,
# CA_WHAT, CA_NOTE. COMP_NUP — строк с обновлениями.
# Закреплён главный пакет — вся группа стоит: обновить родню без него значит
# разъехаться версиями (nginx 7.1 при nginx-common 7.4). Закреплён не главный —
# не берём только его.
comp_apt_load() {
    local i id spec mains extras prods py p v s st m pat members src cnt
    CA_ID=(); CA_NAME=(); CA_MAIN=(); CA_VER=(); CA_CAND=(); CA_UP=(); CA_HOLD=(); CA_N=(); CA_UPN=(); CA_PROD=(); CA_PRODM=(); CA_WHAT=(); CA_NOTE=()
    COMP_NUP=0; COMP_APT=0
    comp_lists_age; comp_lists_when
    comp_apt_ok || return 1
    COMP_APT=1
    local -A ver=() srcof=() held=() cand=() inme=()
    local -a names=() grp=() own=() want=()
    while IFS='|' read -r p v s st; do
        [ -n "$p" ] || continue
        case "${st:1:1}" in i|U|F|W|t) ;; *) continue ;; esac
        p="${p%%:*}"; ver[$p]="$v"; s="${s%% *}"; srcof[$p]="${s:-$p}"; names+=("$p")
    done < <(_comp_dpkg)
    while read -r p; do [ -n "$p" ] && held[${p%%:*}]=1; done < <(_comp_holds)
    py=$(comp_py_name) || py=""
    if [ -z "$py" ]; then
        # /usr/bin/python3 не прочитать — самый новый стоящий python3.X.
        for p in "${names[@]}"; do case "$p" in python3.[0-9]|python3.[0-9][0-9]) [ -z "$py" ] || [ "${p#python3.}" -gt "${py#python3.}" ] && py="$p" ;; esac; done
    fi
    # Проход 1: стоящие пакеты каждой группы и их родня по исходному пакету.
    for id in "${COMP_IDS[@]}"; do
        spec=$(comp_spec "$id"); mains="${spec%%|*}"; spec="${spec#*|}"; extras="${spec%%|*}"
        if [ "$id" = python3 ]; then [ -n "$py" ] || continue; mains="${mains//@py/$py}"; extras="${extras//@py/$py}"; fi
        m=""
        for p in $mains; do [ -n "${ver[$p]:-}" ] && { m="$p"; break; }; done
        members=""; inme=()
        [ -n "$m" ] && { members="$m"; inme[$m]=1; }
        set -f
        for pat in $extras; do
            case "$pat" in
                *[\*\?]*) for p in "${names[@]}"; do [[ "$p" == $pat ]] && [ -z "${inme[$p]:-}" ] && { members+=" $p"; inme[$p]=1; }; done ;;
                *) [ -n "${ver[$pat]:-}" ] && [ -z "${inme[$pat]:-}" ] && { members+=" $pat"; inme[$pat]=1; } ;;
            esac
        done
        set +f
        if [ "$id" = tools ]; then [ -n "$members" ] || continue
        else [ -n "$m" ] || continue; fi
        cnt=0; for p in $members; do cnt=$(( cnt + 1 )); done
        own+=("$members")
        # Родня по исходному пакету: nginx тянет nginx-common и
        # libnginx-mod-stream той же версии. Зависимости из других исходных
        # пакетов apt дотянет сам.
        src=" "; for p in $members; do src+="${srcof[$p]} "; done
        for p in "${names[@]}"; do
            [ -z "${inme[$p]:-}" ] || continue
            case "$src" in *" ${srcof[$p]} "*) members+=" $p"; inme[$p]=1 ;; esac
        done
        CA_ID+=("$id"); CA_MAIN+=("$m"); CA_VER+=("${m:+${ver[$m]}}"); CA_N+=("$cnt"); grp+=("$members")
        CA_NAME+=("$(comp_title "$id" "$py")")
        for p in $members; do want+=("$p"); done
    done
    # Один вызов apt-cache policy на все пакеты.
    if [ "${#want[@]}" -gt 0 ]; then
        p=""
        while IFS= read -r v; do
            case "$v" in
                [!\ ]*:) p="${v%:}"; p="${p%%:*}" ;;
                *Candidate:*) [ -n "$p" ] && { s="${v#*Candidate:}"; cand[$p]="${s// /}"; } ;;
            esac
        done < <(_comp_policy "${want[@]}")
    fi
    # Проход 2: что новее и что закреплено. Стоящие продукты — один раз на
    # загрузку: у goDNS pro признак «стоит» — это запуск python.
    COMP_INST=" "; for p in "${PRODUCTS[@]}"; do prod_installed "$p" && COMP_INST+="$p "; done
    for ((i = 0; i < ${#CA_ID[@]}; i++)); do
        id="${CA_ID[$i]}"; m="${CA_MAIN[$i]}"
        local up="" hd="" upsrc=" " k=0
        for p in ${grp[$i]}; do
            if [ -n "${held[$p]:-}" ]; then hd+="${hd:+ }$p"; continue; fi
            _deb_newer "${ver[$p]}" "${cand[$p]:-}" && { up+="${up:+ }$p=${cand[$p]}"; upsrc+="${srcof[$p]} "; }
        done
        if [ -n "$m" ] && [ -n "${held[$m]:-}" ]; then up=""; upsrc=" "; fi
        # «↑ K из N» — сколько пакетов группы обновится вместе с роднёй:
        # у утилит curl считается один раз, хоть с ним и libcurl.
        for p in ${own[$i]}; do case "$upsrc" in *" ${srcof[$p]} "*) k=$(( k + 1 )) ;; esac; done
        CA_UP+=("$up"); CA_HOLD+=("$hd"); CA_UPN+=("$k")
        if [ -n "$up" ] && [ -n "$m" ] && _deb_newer "${ver[$m]}" "${cand[$m]:-}"; then CA_CAND+=("${cand[$m]}"); else CA_CAND+=(""); fi
        [ -n "$up" ] && COMP_NUP=$(( COMP_NUP + 1 ))
        spec=$(comp_spec "$id"); comp_prods "${spec##*|}"
        CA_PROD+=("$COMP_PRODS"); CA_PRODM+=("$COMP_PRODM")
        CA_WHAT+=("$(comp_what "$id")"); CA_NOTE+=("$(comp_note "$id")")
    done
    return 0
}
comp_idx() {  # comp_idx <id> → COMP_I или rc 1
    local i
    for ((i = 0; i < ${#CA_ID[@]}; i++)); do [ "${CA_ID[$i]}" = "$1" ] && { COMP_I=$i; return 0; }; done
    return 1
}
# Пакеты к обновлению по строкам: comp_pkgs <индекс…> → «пакет пакет…».
comp_pkgs() {
    local i e out=""
    for i in "$@"; do for e in ${CA_UP[$i]:-}; do out+="${out:+ }${e%%=*}"; done; done
    printf '%s' "$out"
}

# Окружения ботов: venv ломается при смене python и сам не чинится.
# comp_bots_load → CB_ID, CB_VENV, CB_VER (python окружения), CB_OK (1/0),
# CB_WHY (что сломано, словами), COMP_PYMM (системный, для справки).
# Сломано — только если python окружения не запускается или запускается не
# тот, на котором окружение собрано (pyvenv.cfg). С системным python3 не
# сравниваем: goVLESS pro собирает venv на первом из python3.13…3.9, и после
# смены Ubuntu бот на оставшемся python3.10 работает.
comp_bot_venv() {
    case "$1" in
        govless) printf '/opt/govless/venv' ;; gotelegram) printf '/opt/gotelegram-bot/venv' ;;
        godns) printf '/opt/godns/bot/venv' ;; goamnezia) printf '/opt/goamnezia-bot/venv' ;;
    esac
}
comp_bot_fix() {
    case "$1" in
        govless)    bi "rm -rf /opt/govless/venv, затем govless → «Бот» → «Установить»" "rm -rf /opt/govless/venv, then govless → “Bot” → “Install”" ;;
        gotelegram) bi "rm -rf /opt/gotelegram-bot/venv, затем gotelegram → «Telegram-бот» → установить/обновить" "rm -rf /opt/gotelegram-bot/venv, then gotelegram → “Telegram bot” → install/update" ;;
        godns)      bi "rm -rf /opt/godns/bot/venv, затем мастер бота godns; не через «снять бота»: так пропадёт токен" "rm -rf /opt/godns/bot/venv, then the godns bot wizard; not via “remove the bot”: the token would be lost" ;;
        goamnezia)  bi "rm -rf /opt/goamnezia-bot/venv, затем goamnezia → «Бот» → 1" "rm -rf /opt/goamnezia-bot/venv, then goamnezia → “Bot” → 1" ;;
    esac
}
comp_bots_load() {
    local r="${GOINST_FS_ROOT:-}" id d cfg vv rv
    CB_ID=(); CB_VENV=(); CB_VER=(); CB_OK=(); CB_WHY=()
    COMP_PYMM=$(comp_py_name) || COMP_PYMM=""; COMP_PYMM="${COMP_PYMM#python}"
    for id in govless gotelegram godns goamnezia; do
        d="$r$(comp_bot_venv "$id")"; cfg="$d/pyvenv.cfg"
        [ -f "$cfg" ] || continue
        vv=$(sed -n -E 's/^version(_info)?[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+).*/\2/p' "$cfg" 2>/dev/null | head -1) || vv=""
        rv=$(_comp_t 5 "$d/bin/python" -V 2>&1) || rv=""
        [[ "$rv" =~ Python[[:space:]]+([0-9]+\.[0-9]+) ]] && rv="${BASH_REMATCH[1]}" || rv=""
        CB_ID+=("$id"); CB_VENV+=("${d#"$r"}"); CB_VER+=("${vv:-$rv}")
        if [ -z "$rv" ]; then
            CB_OK+=(0); CB_WHY+=("$(bi "python ${vv:-?} окружения бота не запускается" "the bot environment's python ${vv:-?} does not start")")
        elif [ -n "$vv" ] && [ "$rv" != "$vv" ]; then
            CB_OK+=(0); CB_WHY+=("$(bi "окружение бота собрано на python ${vv}, а запускается ${rv}" "the bot environment was built on python ${vv} but runs ${rv}")")
        else CB_OK+=(1); CB_WHY+=(""); fi
    done
    return 0
}
# Замечания для меню и сводки при входе: «имя|что|коротко|шаг|err».
comp_bot_probs() {
    local i id msg
    COMP_BOTP=()
    for ((i = 0; i < ${#CB_ID[@]}; i++)); do
        [ "${CB_OK[$i]}" = 1 ] && continue
        id="${CB_ID[$i]}"
        msg="${CB_WHY[$i]}"
        COMP_BOTP+=("$(prod_name "$id")|${msg}|$(prod_name "$id"): $(bi "бот не запустится, python" "the bot will not start, python") ${CB_VER[$i]:-?}|$(prod_cmd "$id")|err")
    done
}

# Движки продуктов — только показ. comp_engines_load → CE_ID, CE_NAME (коротко),
# CE_FULL, CE_VER, CE_PROD, CE_HINT, CE_BAD (1 — сломано), CE_MSG (что сломано).
_comp_ver() { [[ "$1" =~ ([0-9]+\.[0-9]+(\.[0-9]+)*[-+~a-zA-Z0-9.]*) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
comp_engines_load() {
    local r="${GOINST_FS_ROOT:-}" f v out i prods
    CE_ID=(); CE_NAME=(); CE_FULL=(); CE_VER=(); CE_PROD=(); CE_HINT=(); CE_BAD=(); CE_MSG=()
    _ce() { CE_ID+=("$1"); CE_NAME+=("$2"); CE_FULL+=("$3"); CE_VER+=("${4:-?}"); CE_PROD+=("$5"); CE_HINT+=("$6"); CE_BAD+=("${7:-0}"); CE_MSG+=("${8:-}"); }
    if [ -x "$r/usr/local/x-ui/x-ui" ]; then
        out=$(_comp_t 5 "$r/usr/local/x-ui/x-ui" -v 2>&1) || true
        _ce xui "3X-UI" "3X-UI" "$(_comp_ver "$out")" "goVLESS pro, goWARP pro" \
            "$(bi "goVLESS pro панель не обновляет; обновление в меню x-ui — на свой риск: продукт проверен с этой версией" "goVLESS pro does not update the panel; updating from the x-ui menu is at your own risk: the product is tested with this version")"
        for f in "$r"/usr/local/x-ui/bin/xray-linux-*; do
            [ -x "$f" ] || continue
            out=$(_comp_t 5 "$f" version 2>&1) || true
            _ce xray "Xray" "Xray (3X-UI)" "$(_comp_ver "${out%%$'\n'*}")" "goVLESS pro" "$(bi "обновляется вместе с 3X-UI" "updated together with 3X-UI")"
            break
        done
    fi
    if [ -x "$r/usr/local/bin/telemt" ]; then
        out=$(_comp_t 5 "$r/usr/local/bin/telemt" --version 2>&1) || true
        _ce telemt "telemt" "telemt" "$(_comp_ver "$out")" "goTelegram pro" "$(bi "gotelegram → «Управление» → 3" "gotelegram → “Manage” → 3")"
    fi
    # Образы AmneziaWG — теги профилей (.profiles.<p>.image_tag), и только
    # они: рядом лежит откатный .previous.image_tag, а конфиг goAmnezia pro
    # пишет jq многострочно. Поэтому разбор по структуре JSON, python3 есть
    # на любой Ubuntu; нет его — строки нет, а не догадка.
    f="$(prod_config_file goamnezia)"; v=""
    if [ -r "$f" ] && grep -q '"image_tag"' "$f" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
        v=$(_comp_t 5 python3 -I -c 'import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
p = d.get("profiles") if isinstance(d, dict) else None
t = set()
for x in (p.values() if isinstance(p, dict) else []):
    if isinstance(x, dict) and isinstance(x.get("image_tag"), str) and re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", x["image_tag"]):
        t.add(x["image_tag"])
print(", ".join(sorted(t)))' "$f" 2>/dev/null) || v=""
    fi
    if [ -n "$v" ]; then
        _ce awgimg "$(bi "образы AWG" "AWG images")" "$(bi "образы AmneziaWG" "AmneziaWG images")" "$v" "goAmnezia pro" "$(bi "goamnezia → «Обслуживание» → 4" "goamnezia → “Maintenance” → 4")"
    fi
    if [ -r "$r/sys/module/amneziawg/version" ]; then
        v=$(head -1 "$r/sys/module/amneziawg/version" 2>/dev/null) || v=""
        _ce awgmod "$(bi "модуль AWG" "AWG module")" "$(bi "модуль ядра amneziawg" "amneziawg kernel module")" "$v" "goKaskad pro, goAmnezia pro" "$(bi "пересобирается сам под новое ядро (DKMS)" "rebuilt by itself for a new kernel (DKMS)")"
    fi
    v=""; prods=""
    for f in govless:/etc/govless/egress/xray gokaskad:/etc/kaskad/egress/xray; do
        [ -x "$r${f#*:}" ] || continue
        out=$(_comp_t 5 "$r${f#*:}" version 2>&1) || true
        out=$(_comp_ver "${out%%$'\n'*}")
        case " $v " in *" ${out:-?} "*) ;; *) v+="${v:+ }${out:-?}" ;; esac
        prods+="${prods:+, }$(prod_name "${f%%:*}")"
    done
    [ -n "$prods" ] && _ce egress "$(bi "xray прокси TG" "xray TG proxy")" "$(bi "xray прокси API Telegram" "xray of the Telegram API proxy")" "$v" "$prods" "$(bi "ставится один раз и не обновляется" "installed once and never updated")"
    if [ -x "$r/opt/kaskad/accel-ppp/sbin/accel-pppd" ]; then
        out=$(_comp_t 5 "$r/opt/kaskad/accel-ppp/sbin/accel-pppd" -V 2>&1) || true
        _ce accel "accel-ppp" "accel-ppp" "$(_comp_ver "$out")" "goKaskad pro" "$(bi "goKaskad pro: шлюз" "goKaskad pro: gateway")"
    fi
    if [ -x "$r/root/.acme.sh/acme.sh" ]; then
        out=$(_comp_t 5 "$r/root/.acme.sh/acme.sh" --version 2>&1) || true
        _ce acme "acme.sh" "acme.sh" "$(_comp_ver "$out")" "goVLESS pro" "—"
    fi
    comp_bots_load
    for ((i = 0; i < ${#CB_ID[@]}; i++)); do
        if [ "${CB_OK[$i]}" = 1 ]; then
            _ce "bot:${CB_ID[$i]}" "$(bi "бот" "bot") $(prod_cmd "${CB_ID[$i]}")" "$(bi "окружение бота" "bot environment") $(prod_name "${CB_ID[$i]}")" "python ${CB_VER[$i]}" "$(prod_name "${CB_ID[$i]}")" "$(bi "продукт: установка бота из его меню" "the product: bot install from its menu")"
        else
            _ce "bot:${CB_ID[$i]}" "$(bi "бот" "bot") $(prod_cmd "${CB_ID[$i]}")" "$(bi "окружение бота" "bot environment") $(prod_name "${CB_ID[$i]}")" \
                "python ${CB_VER[$i]:-?}" "$(prod_name "${CB_ID[$i]}")" "$(comp_bot_fix "${CB_ID[$i]}")" 1 "${CB_WHY[$i]}"
        fi
    done
    return 0
}

# Журнал: ${GOINST_DIR}/logs/components-<дата>.log, каталог 0700.
comp_log_file() {
    local d="${GOINST_DIR}/logs" f
    mkdir -p "$d" 2>/dev/null; chmod 700 "$d" 2>/dev/null
    f="$d/components-$(date +%Y-%m-%d).log"
    # Полный вывод apt — только root: файл 0600, как и каталог.
    [ -e "$f" ] || { : > "$f"; } 2>/dev/null; chmod 600 "$f" 2>/dev/null
    printf '%s' "$f"
}
# Отметка последней попытки apt-get update, удачной или нет: без неё экран
# при недоступных зеркалах начинал новую проверку на каждом входе.
comp_try_file() { printf '%s/.apt-check' "$GOINST_DIR"; }
comp_try_mark() {
    mkdir -p "$GOINST_DIR" 2>/dev/null
    printf '%(%s)T\n' -1 > "$(comp_try_file)" 2>/dev/null || true
}
# Пора ли проверить списки при входе на экран: списки старше 12 часов И
# прошлая попытка старше часа (GOINST_APT_RETRY, секунды).
comp_autocheck_due() {
    local now t retry="${GOINST_APT_RETRY:-3600}"
    case "$retry" in ''|*[!0-9]*) retry=3600 ;; esac
    comp_lists_stale || return 1
    t=$(head -1 "$(comp_try_file)" 2>/dev/null) || t=""
    case "$t" in ''|*[!0-9]*) return 0 ;; esac
    printf -v now '%(%s)T' -1
    [ $(( now - t )) -ge "$retry" ]
}
# comp_refresh — apt-get update с ограничением времени; вывод в журнал.
# rc 0 — списки свежие; иначе причина словами в COMP_REFRESH_WHY.
comp_refresh() {
    local log out rc=0
    COMP_REFRESH_WHY=""
    if osup_busy; then COMP_REFRESH_WHY=$(osup_busy_text); return 1; fi
    comp_try_mark
    log=$(comp_log_file)
    out=$(LC_ALL=C _comp_t 180 apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o DPkg::Lock::Timeout=60 update 2>&1) || rc=$?
    { printf '== %s apt-get update (rc=%s)\n' "$(date '+%F %T')" "$rc"; printf '%s\n' "$out"; } >> "$log" 2>/dev/null
    if [ "$rc" -eq 0 ]; then printf '%(%s)T\n' -1 > "$(comp_ok_file)" 2>/dev/null; return 0; fi
    case "$out" in
        *"Could not get lock"*|*"Unable to lock"*|*"is held by process"*) COMP_REFRESH_WHY=$(bi "apt занят другим процессом" "apt is busy with another process") ;;
        *"Temporary failure resolving"*|*"Could not resolve"*|*"Failed to fetch"*|*"Unable to connect"*|*"Connection failed"*) COMP_REFRESH_WHY=$(bi "нет связи с репозиториями" "the repositories are unreachable") ;;
        *) COMP_REFRESH_WHY=$(bi "apt-get update вышел с кодом ${rc}" "apt-get update exited with code ${rc}") ;;
    esac
    # Вышло время — это и есть причина, что бы apt ни успел напечатать.
    [ "$rc" -eq 124 ] && COMP_REFRESH_WHY=$(bi "время ожидания вышло (180 с)" "timed out (180 s)")
    return 1
}
# comp_apt_get [-s] <пакеты…> — единственный вызов apt-get, который меняет
# пакеты. Только обновление стоящих: --only-upgrade --no-remove (без
# --no-remove iptables-persistent удалил бы ufw), confold (иначе пропадут
# правки nginx.conf goTelegram pro). Никаких upgrade, dist-upgrade,
# autoremove и установки нового. -s — пробный прогон с теми же ключами.
comp_apt_get() {
    local sim=()
    [ "${1:-}" = -s ] && { sim=(-s); shift; }
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get ${sim[@]+"${sim[@]}"} -y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --only-upgrade --no-remove "$@"
}
# comp_dry <пакеты…> — пробный прогон: COMP_DRY_INST (что обновится),
# COMP_DRY_KEPT (что apt отложил), COMP_DRY_ERR (первая ошибка).
comp_dry() {
    local out rc=0 l w sect=""
    COMP_DRY_INST=""; COMP_DRY_KEPT=""; COMP_DRY_ERR=""
    out=$(LC_ALL=C comp_apt_get -s "$@" 2>&1) || rc=$?
    while IFS= read -r l; do
        case "$l" in
            "Inst "*) l="${l#Inst }"; l="${l%% *}"; case " $COMP_DRY_INST " in *" $l "*) ;; *) COMP_DRY_INST+="${COMP_DRY_INST:+ }$l" ;; esac; sect="" ;;
            *"kept back:"|*"deferred due to phasing:") sect=kept ;;
            "  "*) [ "$sect" = kept ] && { set -f; for w in $l; do COMP_DRY_KEPT+="${COMP_DRY_KEPT:+ }$w"; done; set +f; } ;;
            "E: "*) [ -n "$COMP_DRY_ERR" ] || COMP_DRY_ERR="${l#E: }"; sect="" ;;
            *) sect="" ;;
        esac
    done <<<"$out"
    [ "$rc" -eq 0 ] || { [ -n "$COMP_DRY_ERR" ] || COMP_DRY_ERR="apt-get -s: rc=${rc}"; return 1; }
    return 0
}
# Перезапуск служб: NEEDRESTART_MODE=a оставлен решением заказчика 14.10 —
# службы на обновлённых библиотеках (openssl, libcurl, python) иначе так и
# работали бы со старыми. Человеку об этом говорим до вопроса и после.
comp_restart_note() {
    bi "Службы, которым нужны обновлённые библиотеки, перезапустятся сами (needrestart): VPN-клиенты переподключатся." \
       "Services that use the updated libraries restart by themselves (needrestart): VPN clients reconnect."
}
# comp_nr_units <файл> <с какой строки> — какие службы перезапустил needrestart:
# после «Restarting services...» идут строки « systemctl restart a.service b.service».
comp_nr_units() {
    tail -n +"$2" "$1" 2>/dev/null | awk '
        /^Restarting services/ { on = 1; next }
        on && /^ *systemctl restart / { for (i = 3; i <= NF; i++) { u = $i; sub(/\.service$/, "", u); if (!(u in s)) { s[u] = 1; out = out (out == "" ? "" : ", ") u } } next }
        on && !/^ / { on = 0 }
        END { print out }'
}
# comp_run <пакеты…> — обновление; вывод человеку целиком и в журнал.
# COMP_NR — службы, которые перезапустил needrestart (если он это сказал).
comp_run() {
    local log rc from
    log=$(comp_log_file); COMP_LOG="$log"; COMP_NR=""
    printf '== %s apt-get install --only-upgrade --no-remove %s\n' "$(date '+%F %T')" "$*" >> "$log" 2>/dev/null
    from=$(( $(wc -l < "$log" 2>/dev/null || echo 0) + 1 ))
    comp_apt_get "$@" 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    printf '== rc=%s\n' "$rc" >> "$log" 2>/dev/null
    COMP_NR=$(comp_nr_units "$log" "$from")
    return "$rc"
}
# comp_after <rc> <id…> — итог по строкам и службы стоящих продуктов.
# До вызова: COMP_BEFORE — «id=версия=кандидат …» до обновления.
comp_after() {
    local rc="$1" id e old want v n=0 p u bad="" t
    shift
    comp_apt_load >/dev/null 2>&1
    for id in "$@"; do
        e=""; for v in $COMP_BEFORE; do [ "${v%%=*}" = "$id" ] && e="$v"; done
        old="${e#*=}"; want="${old#*=}"; old="${old%%=*}"
        # Строки больше нет (пакет сняли) — индекс прошлой строки не годится.
        v=""; COMP_I=-1; comp_idx "$id" && v="${CA_VER[$COMP_I]}"
        # Подпись — как в таблице («python 3.12», а не «python3»).
        t=$(comp_title "$id"); [ "$COMP_I" -ge 0 ] && [ -n "${CA_NAME[$COMP_I]:-}" ] && t="${CA_NAME[$COMP_I]}"
        if [ "$rc" -ne 0 ]; then err "${t}: $(bi "apt вышел с кодом ${rc}" "apt exited with code ${rc}")"
        elif [ -n "$v" ] && [ "$v" != "$old" ]; then ok "${t}: $(bi "стала" "now") ${v}"
        elif [ -z "$want" ] && [ "$COMP_I" -ge 0 ] && [ -z "${CA_UP[$COMP_I]:-}" ]; then ok "${t}: $(bi "пакеты группы обновлены" "the group packages are updated")"
        elif [ -z "$old" ]; then warn "${t}: $(bi "часть пакетов apt отложил" "apt held some packages back")"
        else warn "${t}: $(bi "осталась ${v:-$old} — apt отложил" "stayed ${v:-$old} — apt held it back")"; fi
    done
    if command -v systemctl >/dev/null 2>&1; then
        for p in "${PRODUCTS[@]}"; do
            prod_installed "$p" || continue
            for u in $(prod_units "$p"); do
                [ "$(unit_state "$u")" = down ] && { bad+=" $u"; n=$(( n + 1 )); err "$(prod_name "$p"): $(bi "служба ${u} не работает" "the ${u} unit is not running") → journalctl -u ${u}"; }
            done
        done
        [ "$n" -eq 0 ] && ok "$(bi "Службы стоящих продуктов работают." "The installed products' units are running.")"
    fi
    [ -n "${COMP_NR:-}" ] && say "$(bi "needrestart перезапустил службы:" "needrestart restarted the services:") ${COMP_NR}"
    [ -n "${COMP_LOG:-}" ] && say "$(bi "Полный вывод apt:" "Full apt output:") ${COMP_LOG}"
    return 0
}
comp_before() {  # comp_before <индекс…> → COMP_BEFORE
    local i
    COMP_BEFORE=""
    for i in "$@"; do COMP_BEFORE+="${COMP_BEFORE:+ }${CA_ID[$i]}=${CA_VER[$i]}=${CA_CAND[$i]}"; done
}

# Таблица для --components: в stderr, кириллица в колонках — через pad_to.
# Колонки — по самому длинному значению: версии Debian и список образов
# резать нельзя, ради них команду и зовут.
comp_table() {
    local i v a l w1=9 w2=5 w3=8 wv=6 wn=10
    local -a cv=() ca=()
    comp_apt_load >/dev/null 2>&1
    comp_engines_load
    print_header "$(bi "Компоненты: системные пакеты продуктов" "Components: the products' system packages")"
    if [ "${COMP_APT:-0}" != 1 ]; then warn "$(bi "apt недоступен — показывать нечего." "apt is unavailable — nothing to show.")"
    else
        for ((i = 0; i < ${#CA_ID[@]}; i++)); do
            v="${CA_VER[$i]}"; a="${CA_CAND[$i]}"
            if [ "${CA_ID[$i]}" = tools ]; then v="${CA_N[$i]} $(bi "пакетов" "packages")"; fi
            if [ -n "${CA_UP[$i]}" ]; then
                [ -n "$a" ] || a="${CA_UPN[$i]:-?} $(bi "из" "of") ${CA_N[$i]}"
                a="↑ $a"
            elif [ -n "${CA_HOLD[$i]}" ]; then a="! $(bi "закреплён" "held")"
            else a=$(bi "новее нет" "nothing newer"); fi
            cv+=("$v"); ca+=("$a")
            l=$(str_len "${CA_NAME[$i]}"); [ "$l" -gt "$w1" ] && w1=$l
            l=$(str_len "$v"); [ "$l" -gt "$w2" ] && w2=$l
            l=$(str_len "$a"); [ "$l" -gt "$w3" ] && w3=$l
        done
        printf "  ${DIM}%s  %s  %s  %s${NC}\n" "$(pad_to "$(bi "компонент" "component")" "$w1")" "$(pad_to "$(bi "стоит" "installed")" "$w2")" \
            "$(pad_to "$(bi "доступно" "available")" "$w3")" "$(bi "для" "for")" >&2
        for ((i = 0; i < ${#CA_ID[@]}; i++)); do
            # Ни один продукт строки не стоит — список приглушён и помечен.
            if [ "${CA_PRODM[$i]}" = 1 ]; then v="${DIM}${CA_PROD[$i]} ($(bi "не стоят" "not installed"))${NC}"; else v="${CA_PROD[$i]}"; fi
            printf "  %s  %s  %s  %b\n" "$(pad_to "${CA_NAME[$i]}" "$w1")" "$(pad_to "${cv[$i]}" "$w2")" "$(pad_to "${ca[$i]}" "$w3")" "$v" >&2
            [ -n "${CA_HOLD[$i]}" ] && printf "      ${YELLOW}! %s %s${NC}\n" "$(bi "закреплён (apt-mark hold):" "held (apt-mark hold):")" "${CA_HOLD[$i]}" >&2
        done
    fi
    if [ "${#CE_ID[@]}" -gt 0 ]; then
        for ((i = 0; i < ${#CE_ID[@]}; i++)); do
            l=$(str_len "${CE_FULL[$i]}"); [ "$l" -gt "$wn" ] && wn=$l
            l=$(str_len "${CE_VER[$i]}"); [ "$l" -gt "$wv" ] && wv=$l
        done
        echo "" >&2
        echo -e "  ${BOLD}$(bi "Движки продуктов (обновляет продукт)" "Product engines (updated by the product)")${NC}" >&2
        for ((i = 0; i < ${#CE_ID[@]}; i++)); do
            if [ "${CE_BAD[$i]}" = 1 ]; then
                printf "  %s  ${RED}✗ %s${NC}\n" "$(pad_to "${CE_FULL[$i]}" "$wn")" "${CE_MSG[$i]}" >&2
            else
                printf "  %s  %s  %s\n" "$(pad_to "${CE_FULL[$i]}" "$wn")" "$(pad_to "${CE_VER[$i]}" "$wv")" "${CE_PROD[$i]}" >&2
            fi
            printf "      ${DIM}%s${NC}\n" "${CE_HINT[$i]}" >&2
        done
    fi
    echo "" >&2
    echo -e "  ${DIM}$(comp_lists_label)${NC}" >&2
    return 0
}
# comp_update <id…|all> [--yes] — команда --components update.
# Код: 0 — обновлено, 1 — ошибка apt, 2 — обновлять нечего (или отказ), 64 — неизвестный id.
comp_update() {
    local yes="" ask="" a ids=() idx=() i pkgs rc=0
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            --ask) ask=1 ;;     # из меню: человек уже отвечает, терминал проверен меню
            all) ids+=(all) ;;
            *) if comp_valid "$a"; then ids+=("$a")
               else err "$(bi "Нет такого компонента: ${a}. Можно: ${COMP_IDS[*]}, all." "No such component: ${a}. Allowed: ${COMP_IDS[*]}, all.")"; return 64; fi ;;
        esac
    done
    [ "${#ids[@]}" -gt 0 ] || { usage; return 64; }
    osup_busy_refuse && return 1
    # Без терминала спросить некого — отказ до вопросов, как у --uninstall.
    if [ -z "$yes" ] && [ -z "$ask" ] && [ ! -t 0 ]; then
        err "$(bi "Без терминала спросить некого: goinstall --components update ${ids[*]} --yes" "No terminal to ask: goinstall --components update ${ids[*]} --yes")"
        return 3
    fi
    comp_apt_ok || { err "$(bi "apt недоступен." "apt is unavailable.")"; return 1; }
    comp_apt_load >/dev/null 2>&1
    for a in "${ids[@]}"; do
        if [ "$a" = all ]; then for ((i = 0; i < ${#CA_ID[@]}; i++)); do [ -n "${CA_UP[$i]}" ] && idx+=("$i"); done
        elif comp_idx "$a" && [ -n "${CA_UP[$COMP_I]}" ]; then idx+=("$COMP_I")
        else say "$(comp_title "$a"): $(if comp_idx "$a"; then if [ -n "${CA_HOLD[$COMP_I]}" ]; then bi "закреплён (apt-mark hold), не обновляется" "held (apt-mark hold), not updated"; else bi "новее нет" "nothing newer"; fi; else bi "не стоит" "not installed"; fi)"; fi
    done
    [ "${#idx[@]}" -gt 0 ] || { ok "$(bi "Обновлять нечего." "Nothing to update.")"; return 2; }
    pkgs=$(comp_pkgs "${idx[@]}")
    print_header "$(bi "Обновить компоненты" "Update the components")"
    for i in "${idx[@]}"; do
        say "${CA_NAME[$i]}  ${CA_VER[$i]:-${CA_N[$i]} $(bi "пакетов" "packages")}${CA_CAND[$i]:+ → ${CA_CAND[$i]}}"
        [ -n "${CA_NOTE[$i]}" ] && echo -e "      ${DIM}${CA_NOTE[$i]}${NC}" >&2
    done
    # shellcheck disable=SC2086
    if ! comp_dry $pkgs; then err "$(bi "Пробный прогон apt не прошёл:" "The apt dry run failed:") ${COMP_DRY_ERR}"; return 1; fi
    local n=0 w; for w in $COMP_DRY_INST; do n=$(( n + 1 )); done
    say "$(bi "apt обновит пакетов:" "apt will upgrade packages:") ${n}${COMP_DRY_INST:+ — $COMP_DRY_INST}"
    [ -n "$COMP_DRY_KEPT" ] && warn "$(bi "отложено:" "held back:") ${COMP_DRY_KEPT}"
    if [ "$n" -eq 0 ]; then ok "$(bi "Обновлять нечего: apt ничего не обновит." "Nothing to update: apt will upgrade nothing.")"; return 2; fi
    echo -e "  ${DIM}$(comp_restart_note)${NC}" >&2
    if [ -z "$yes" ]; then
        confirm "$(bi "Запустить обновление?" "Run the update?")" y || { say "$(bi "Отменено, ничего не обновлено." "Cancelled, nothing updated.")"; return 2; }
    fi
    comp_before "${idx[@]}"
    # shellcheck disable=SC2086
    comp_run $pkgs >&2 || rc=$?
    comp_after "$rc" $(for i in "${idx[@]}"; do printf '%s ' "${CA_ID[$i]}"; done)
    [ "$rc" -eq 0 ] || return 1
    return 0
}
# goinstall --components [refresh | update <id…|all> [--yes]]
comp_cli() {
    case "${1:-}" in
        '') comp_table; return 0 ;;
        refresh)
            comp_apt_ok || { err "$(bi "apt недоступен." "apt is unavailable.")"; return 1; }
            say "$(bi "Проверяю обновления: apt-get update…" "Checking for updates: apt-get update…")"
            comp_refresh || warn "$(bi "Не вышло:" "Failed:") ${COMP_REFRESH_WHY}. $(bi "Показываю по прежним спискам." "Showing the previous lists.")"
            comp_table; return 0 ;;
        update) shift; comp_update "$@"; return $? ;;
        *) usage; return 64 ;;
    esac
}

# Нумерованное меню «Компоненты» — запасной путь, отметок в нём нет: строка —
# обновить этот компонент после подтверждения. Пункты объявляются в
# MENU_ITEMS, как у остальных меню.
COMP_KEYS=(1 2 3 4 5 6 7 8 9 b c d e f g h i j k l m n p s t v w x y z)
# Пояснение строками под пунктом, с переносом по ширине окна: у движков —
# кто их обновляет, у сломанного окружения бота — что сломано и как починить.
# Обрезать нельзя: это и есть то, ради чего строка.
_comp_menu_note() {  # _comp_menu_note <текст> [r]
    local l pre="${2:+$2:}" w
    w=$(( $(menu_cols) - 9 )); [ "$w" -ge 20 ] || w=20
    ui_wrap "$1" "$w"
    for l in "${UI_WRAP[@]}"; do MENU_ITEMS+=("-||||${pre}  ${l}"); done
}
menu_items_components() {
    local i k st ex l ws=0 we=0 up
    MENU_REFRESH_SEC=0; MENU_REFRESH_HOOK=""; MENU_FOOTER_INFO=""
    MENU_TITLE="$(bi "Компоненты" "Components")"
    MENU_SUB="$(bi "системные пакеты продуктов" "the products' system packages") · $(comp_lists_label)"
    MENU_ITEMS=(); COMP_MKEY=()
    if [ "${COMP_APT:-0}" != 1 ]; then MENU_ITEMS+=("-|$(bi "apt недоступен" "apt is unavailable")|||")
    fi
    # Сначала строки apt — по ним ширина колонок: версии Debian длинные, а
    # резать «↑ 26.1.3-0ubuntu1~24.04.1» нельзя.
    local -a rows=()
    for ((i = 0; i < ${#CA_ID[@]} && i < ${#COMP_KEYS[@]}; i++)); do
        k="${COMP_KEYS[$i]}"; COMP_MKEY+=("$k")
        if [ "${CA_ID[$i]}" = tools ]; then st="${CA_N[$i]} $(bi "пакетов" "packages")"; else st="${CA_VER[$i]}"; fi
        if [ -n "${CA_UP[$i]}" ]; then
            st="g:↑ ${st}"
            if [ -n "${CA_CAND[$i]}" ]; then ex="d:${CA_CAND[$i]}"; else ex="d:${CA_UPN[$i]:-?} $(bi "из" "of") ${CA_N[$i]}"; fi
        elif [ -n "${CA_HOLD[$i]}" ]; then st="y:! ${st}"; ex="y:$(bi "закреплён" "held")"
        else st="d:✓ ${st}"; ex="d:$(bi "новее нет" "nothing newer")"; fi
        l=$(str_len "${st#*:}"); [ "$l" -gt "$ws" ] && ws=$l
        l=$(str_len "${ex#*:}"); [ "$l" -gt "$we" ] && we=$l
        rows+=("${k}|${CA_NAME[$i]}|${st}|${ex}|${CA_PROD[$i]}")
    done
    for ((i = 0; i < ${#CE_ID[@]}; i++)); do l=$(str_len "x ${CE_VER[$i]}"); [ "$l" -gt "$ws" ] && ws=$l; done
    [ "$ws" -ge 12 ] || ws=12; [ "$we" -ge 10 ] || we=10
    MENU_W_STATUS=$ws; MENU_W_EXTRA=$we
    up=$(bi "Обновить всё" "Update all")
    # Ширина имён — по пунктам с колонками; подписи действий без колонок
    # печатаются целиком (menu_build_rows), их ширина колонку не раздувает.
    MENU_ITEMS=(${MENU_ITEMS[@]+"${MENU_ITEMS[@]}"} ${rows[@]+"${rows[@]}"})
    for ((i = 0; i < ${#CE_ID[@]}; i++)); do MENU_ITEMS+=("-|${CE_NAME[$i]}|d:${CE_VER[$i]}||"); done
    menu_fit_widths 12
    MENU_ITEMS=(${MENU_ITEMS[@]+"${MENU_ITEMS[@]:0:$(( ${#MENU_ITEMS[@]} - ${#CE_ID[@]} ))}"})
    if [ "${#CE_ID[@]}" -gt 0 ]; then
        MENU_ITEMS+=("-|||")
        MENU_ITEMS+=("-|$(bi "Движки продуктов — обновляет продукт, не goInstaller" "Product engines — updated by the product, not goInstaller")|||")
        for ((i = 0; i < ${#CE_ID[@]}; i++)); do
            if [ "${CE_BAD[$i]}" = 1 ]; then st="r:✗ ${CE_VER[$i]}"; else st="d:${CE_VER[$i]}"; fi
            if [ "${CE_BAD[$i]}" = 1 ]; then
                MENU_ITEMS+=("-|${CE_NAME[$i]}|${st}|r:$(bi "сломано" "broken")|")
                _comp_menu_note "✗ ${CE_MSG[$i]}" r
                _comp_menu_note "$(bi "Починить:" "To fix:") ${CE_HINT[$i]}"
            else
                # «для кого: кто обновляет» — в строку, если влезает целиком,
                # иначе строкой ниже.
                l="${CE_PROD[$i]}: ${CE_HINT[$i]}"; [ "${CE_HINT[$i]}" = "—" ] && l="${CE_PROD[$i]}"
                if [ "$MENU_W_SUB" -gt 0 ] && [ "$(str_len "${CE_PROD[$i]}")" -le "$MENU_W_EXTRA" ] && [ "$(str_len "${CE_HINT[$i]}")" -le "$MENU_W_SUB" ]; then
                    MENU_ITEMS+=("-|${CE_NAME[$i]}|${st}|d:${CE_PROD[$i]}|${CE_HINT[$i]}")
                else
                    MENU_ITEMS+=("-|${CE_NAME[$i]}|${st}|d:|")
                    _comp_menu_note "$l"
                fi
            fi
        done
    fi
    MENU_ITEMS+=("-|||")
    MENU_ITEMS+=("a|${up} (${COMP_NUP:-0})|||$(bi "все компоненты с обновлениями" "every component with updates")")
    MENU_ITEMS+=("r|$(bi "Проверить обновления" "Check for updates")|||apt-get update")
    MENU_ITEMS+=("0|$(bi "Назад" "Back")|||")
}
components_menu() {
    local i
    comp_apt_load >/dev/null 2>&1; comp_engines_load
    while true; do
        menu_items_components
        pick_menu || return 0
        case "$PICK_KEY" in
            0) return 0 ;;
            a) comp_menu_update all ;;
            r) say "$(bi "Проверяю обновления: apt-get update…" "Checking for updates: apt-get update…")"
               comp_refresh || { warn "$(bi "Не вышло:" "Failed:") ${COMP_REFRESH_WHY}"; sleep 2; }
               comp_apt_load >/dev/null 2>&1 ;;
            *) for ((i = 0; i < ${#COMP_MKEY[@]}; i++)); do
                   [ "${COMP_MKEY[$i]}" = "$PICK_KEY" ] && { comp_menu_update "${CA_ID[$i]}"; break; }
               done ;;
        esac
    done
}
# Обновить из нумерованного меню: та же comp_update, вопрос — confirm.
comp_menu_update() {
    comp_update --ask "$@"
    comp_apt_load >/dev/null 2>&1; comp_engines_load
    echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") " >&2; read -r || true
}

# ── защита от сканеров и ботов (1.2.0) ─────────────────────────────────
# Решение заказчика 02.11.2026: новое исключение из «goInstaller сам ничего
# не настраивает» (как размер пакета и «Компоненты»), только с согласия.
# Своя таблица nft inet goinstall_shield — и только она. Никогда: flush
# ruleset, /etc/nftables.conf, служба nftables, ufw, iptables, Docker и
# таблицы продуктов (стражи в наборе). Входящие из сетей списка — drop
# (сканер не видит порта), исходящие в сети ВК — reject (по выбору: иначе
# приложения висят до тайм-аута). SSH открыт всегда: его порты и адреса
# сервера пересчитываются при каждом применении.
# Списки — открытый C24Be/AS_Network_List, БЕЗ ключа клуба: чужому
# репозиторию ключ не нужен и не положен. Чужой список — чужой ввод:
# строгий разбор python3 -I + ipaddress до применения; не прошёл — работает
# прошлый принятый.
SHIELD_REPO="C24Be/AS_Network_List"
SHIELD_REF="main"
SHIELD_PATH="blacklists"
SHIELD_FILES=(blacklist-v4.txt blacklist-v6.txt blacklist-vk-v4.txt blacklist-vk-v6.txt blacklist_with_comments.txt)
SHIELD_TABLE="goinstall_shield"
SHIELD_TVK="TVK-AS"
# Что не работает при закрытом ВК — по пункту на строку (решение владельца
# 03.11.2026, 1.2.3). Состав сверен 03.11.2026: адреса vk.com, vkvideo.ru,
# ok.ru, mail.ru, cloud.mail.ru, max.ru, dzen.ru, rustore.ru, youla.ru,
# vkplay.ru, cloud.vk.com — в сетях blacklist-vk-v4 (подписи сетей в
# blacklist_with_comments: VKONTAKTE-FRONT, ODNOKLASSNIKI-FRONT, VK pochta
# mail.ru, VKCS «VK Cloud Solutions», VK-FRONT «VK Services»). Чего в сетях
# ВК нет (boosty.to, my.games), не пишем.
SHIELD_VK_SVC_RU=$'ВКонтакте и VK Видео\nОдноклассники\nMail.ru (почта, облако)\nмессенджер Макс\nДзен\nRuStore\nЮла\nVK Play\nVK Cloud\nи другие сервисы VK'
SHIELD_VK_SVC_EN=$'VKontakte and VK Video\nOdnoklassniki (OK)\nMail.ru (mail, cloud)\nMax messenger\nDzen\nRuStore\nYoula\nVK Play\nVK Cloud\nand other VK services'
SHIELD_UNIT="goinstall-shield"
# Версия текста правил — в отпечатке (_shield_fp): сменился текст (порядок
# цепочки, новые правила) — его ставит первый же такт после обновления, а не
# следующее обновление списка. 2 — drop по ct direction original (1.2.1),
# 3 — правила счёта статистики (1.2.4), 4 — выход служб-прокси считается
# клиентами, срок записи в наборе портов (REVIEW-6 №6, №7з).
SHIELD_RULES_REV=4
# Службы-прокси: их выход к ВК — трафик клиентов VPN, а не самого сервера
# (REVIEW-6 №6, сверено с prod_units): x-ui — goVLESS pro и любая 3X-UI (xray
# идёт в её cgroup), xray — отдельный xray, telemt — goTelegram pro, mtg —
# MTProxy службой. MTProxy в контейнере (mtproto-proxy) и AmneziaWG goAmnezia pro
# выходят пересылкой (forward) и считаются клиентами и так.
SHIELD_PROXY_UNITS="x-ui xray telemt mtg"
SHIELD_MIN4=300
# Потолки охвата чужого списка — в адресах после слияния, в /24 (v4) и /48
# (v6), а не в строках: 576 строк «все /8» накрыли бы весь IPv4. Списки
# 03.11.2026: общий v4 — 1658 /24 (1151 строка, самая широкая /16), ВК v4 —
# 739 и целиком внутри общего; общий v6 — 1 437 701 /48 (16 сетей, самые
# широкие /29), ВК v6 — 1 572 864 (три /29, две вне общего v6).
# v4: 16384 /24 = 4 194 304 адреса (как одна /10, 0,1% IPv4) — ~9,9× нынешнего
# общего: запас на рост проекта, а подменённый список закроет не больше /10.
# v6: 16 777 216 /48 = 256 /32 — ~11,7× общего и ~10,7× ВК. Рост охвата за
# одно обновление — не больше втрое (как у строк), считая от прошлого, но не
# меньше пола: принятый однажды крошечный список (ВК из одной /24) иначе
# отклонял бы каждый следующий нормальный, и обновления вставали навсегда.
# Пол — 1/16 потолка: втрое от пола (3072 /24, 3 145 728 /48) ниже потолка.
SHIELD_MAX4=16384
SHIELD_MAX6=16777216
SHIELD_FLOOR4=1024
SHIELD_FLOOR6=1048576
SHIELD_SAID=""; SHIELD_ERR=""; SHIELD_LOCKN=0; SHIELD_LOCKFD=""; SHIELD_PROBS=(); SHS_ST=none; SHS_TEXT=""; SHS_WHY=""
SHIELD_VKERR=""; SHIELD_VKNONE=""; SHIELD_GH=(); SHIELD_GHMISS=""; SHIELD_GHNET=""; SHIELD_GHADDR=""

_shield_paths() {
    SHIELD_DIR="${GOINST_SHIELD_DIR:-${GOINST_DIR}/shield}"
    SHIELD_LOG="$SHIELD_DIR/shield.log"
    SHIELD_RUNNER="$SHIELD_DIR/runner.sh"
    SHIELD_RUN="${GOINST_SHIELD_RUN:-/run/goinstall-shield.boot}"
    SHIELD_UNITD="${GOINST_SYSTEMD_DIR:-/etc/systemd/system}"
}
# Набор задаёт «сейчас» (сводка при входе сверяет с ним возраст снимка).
_shield_now() {
    if [ -n "${GOINST_TEST:-}" ] && [[ "${GOINST_SHIELD_NOW:-}" =~ ^[0-9]{1,12}$ ]]; then printf '%s' "$GOINST_SHIELD_NOW"; return 0; fi
    printf '%(%s)T' -1
}

# Все вызовы nft — только здесь (страж в наборе). В наборе — только
# заглушка GOINST_SHIELD_NFT: настоящий nft тесты не трогают никогда.
_shield_nft() {
    if [ -n "${GOINST_TEST:-}" ]; then
        [ -n "${GOINST_SHIELD_NFT:-}" ] && [ -x "$GOINST_SHIELD_NFT" ] || return 127
        "$GOINST_SHIELD_NFT" "$@"; return $?
    fi
    nft "$@"
}
_shield_have_nft() {
    if [ -n "${GOINST_TEST:-}" ]; then [ -n "${GOINST_SHIELD_NFT:-}" ] && [ -x "$GOINST_SHIELD_NFT" ]
    else command -v nft >/dev/null 2>&1; fi
}

# Разбор и сборка — python3 -I (без site, без чужого PYTHONPATH) с модулем
# ipaddress. Режимы:
#   list <файл> <4|6> <куда>   — строгий разбор списка; печатает число сетей.
#       Код 2 — мусор (строка не сеть), 3 — сеть шире /8 (v6: /16),
#       4 — слишком большой; печатает причину. Отказ — всему списку.
#   within <sub> <sup> — каждая сеть sub внутри sup; нет — код 7 «out <сеть>».
#   hits <vk4> <vk6> <исключения> <адрес…> — ни одна сеть не содержит
#       адресов; содержит — код 7 «hit <сеть> <адрес>» (адреса GitHub в
#       списке ВК). Адрес внутри своего исключения не в счёт: исключения
#       пропускает и цепочка ВК (@allow4/@allow6 раньше reject).
#   tvk <файл> <имя> <scan4> <scan6> <куда4> <куда6> — сети блоков AS с этим
#       именем (исключения по умолчанию), только пересекающие принятый список.
#   addr <allow|block> <строка> <адреса> — ввод человека; печатает сеть.
#       Код 2 — не сеть, 3 — шире /8 (/16), 5 — частная или служебная,
#       6 — внутри адрес сервера.
#   render <каталог> <scan 0|1> <vk 0|1> <порты> <адреса> <куда> [уровень
#       статистики 0–3] — shield.nft. Печатает «nets=N nx=N dropped=N»,
#       выкинутые сети — в <каталог>/dropped.
_shield_py() {
    # umask 077: и shield.nft, и списки, и dropped — только для root.
    ( umask 077; exec python3 -I - "$@" ) <<'PY'
import sys, re, ipaddress
RX = re.compile(r'^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$')
TOK = re.compile(r'(?<![0-9A-Za-z:./])([0-9A-Fa-f:.]+/[0-9]{1,3})(?![0-9A-Za-z])')
WIDE = {4: 8, 6: 16}
MAXN = 100000
LIMIT = 8000000
SPECIAL = {
    4: ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
        '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16',
        '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'],
    6: ['::/128', '::1/128', '::ffff:0:0/96', '64:ff9b::/96', '64:ff9b:1::/48', '100::/64',
        '2001:db8::/32', 'fc00::/7', 'fe80::/10', 'ff00::/8'],
}
SPECIAL = {f: [ipaddress.ip_network(x) for x in v] for f, v in SPECIAL.items()}
TABLE = 'inet goinstall_shield'

def fail(rc, msg):
    sys.stdout.write(msg + '\n')
    sys.exit(rc)

def safe(s):
    return ''.join(c if (c.isascii() and (c.isalnum() or c in './:-')) else '?' for c in s[:40])

def lines(path):
    with open(path, 'rb') as fh:
        data = fh.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError('big')
    t = data.decode('utf-8', 'replace')
    if t.startswith('﻿'):
        t = t[1:]
    return t.splitlines()

def net(s, fam=None):
    if len(s) > 49 or not RX.match(s):
        return None
    try:
        n = ipaddress.ip_network(s, strict=True)
    except ValueError:
        return None
    if fam and n.version != fam:
        return None
    return n

def load(path):
    out = []
    try:
        src = lines(path)
    except (OSError, ValueError):
        return out
    for l in src:
        n = net(l.strip())
        if n is not None and n.prefixlen >= WIDE[n.version]:
            out.append(n)
    return out

def own_load(path):
    own = {4: [], 6: []}
    try:
        src = lines(path)
    except (OSError, ValueError):
        return own
    for l in src:
        try:
            a = ipaddress.ip_address(l.strip())
        except ValueError:
            continue
        own[a.version].append(a)
    return own

def write(path, nets):
    with open(path, 'w') as fh:
        fh.write(''.join(str(n) + '\n' for n in nets))

def collapse(nets):
    return list(ipaddress.collapse_addresses(sorted(set(nets))))

def why_bad(n, own):
    if any(n.overlaps(m) for m in SPECIAL[n.version]):
        return 'special'
    for a in own[n.version]:
        if a in n:
            return 'own ' + str(a)
    return None

def units(nets, fam):
    # Охват: сколько адресов закроет набор после слияния пересечений, в /24
    # (v4) или /48 (v6), с округлением вверх.
    host = 8 if fam == 4 else 80
    a = sum(n.num_addresses for n in collapse(nets))
    return (a + (1 << host) - 1) >> host

def cmd_list(path, fam, dst):
    fam = int(fam)
    seen = set()
    try:
        src = lines(path)
    except ValueError:
        fail(4, 'big')
    for no, raw in enumerate(src, 1):
        s = raw.split('#', 1)[0].strip()
        if not s:
            continue
        n = net(s, fam)
        if n is None:
            fail(2, 'garbage %d %s' % (no, safe(s)))
        if n.prefixlen < WIDE[fam]:
            fail(3, 'wide %s' % n)
        seen.add(n)
        if len(seen) > MAXN:
            fail(4, 'many %d' % MAXN)
    res = sorted(seen)
    write(dst, res)
    print('%d %d' % (len(res), units(res, fam)))

def cmd_within(sub, sup):
    # Каждая сеть sub — внутри какой-то сети sup. sup слит: сети не
    # пересекаются и упорядочены, кандидат один — ближайшая слева.
    import bisect
    big = collapse(load(sup))
    keys = [(n.version, int(n.network_address)) for n in big]
    for n in load(sub):
        i = bisect.bisect_right(keys, (n.version, int(n.network_address))) - 1
        if i < 0 or big[i].version != n.version or not n.subnet_of(big[i]):
            fail(7, 'out %s' % n)
    print('ok')

def cmd_hits(l4, l6, exf, *addrs):
    nets = load(l4) + load(l6)
    ex = load(exf)
    for s in addrs:
        try:
            a = ipaddress.ip_address(s.strip())
        except ValueError:
            continue
        if any(m.version == a.version and a in m for m in ex):
            continue
        for n in nets:
            if n.version == a.version and a in n:
                fail(7, 'hit %s %s' % (n, a))
    print('ok')

def cmd_tvk(path, name, l4, l6, d4, d6):
    # Формат файла (02.11.2026): блок «---» / «# Networks announced by ASn» /
    # «# AS-Name (ORG): ИМЯ (ORG)», под ним голые сети до следующего блока;
    # либо «# NET-Name: сеть ИМЯ …» и сеть следующей строкой.
    scan = {4: load(l4), 6: load(l6)}
    found = {4: set(), 6: set()}
    who = re.compile(r'(?<![A-Za-z0-9-])' + re.escape(name) + r'(?![A-Za-z0-9-])')
    try:
        src = lines(path)
    except (OSError, ValueError):
        src = []
    cur = False
    for raw in src:
        s = raw.strip()
        toks = []
        if s == '---' or s.startswith('# Networks announced') or s.startswith('# NET-Name'):
            cur = False
        if s.startswith('#') or s == '---':
            if who.search(s):
                cur = True
                toks = TOK.findall(s)
        elif cur:
            toks = [s.split('#', 1)[0].strip()]
        for tok in toks:
            try:
                n = ipaddress.ip_network(tok, strict=False)
            except ValueError:
                continue
            if n.prefixlen < WIDE[n.version]:
                continue
            if any(n.overlaps(m) for m in scan[n.version]):
                found[n.version].add(n)
    r4 = collapse(found[4])[:1000]
    r6 = collapse(found[6])[:1000]
    write(d4, r4)
    write(d6, r6)
    print(len(r4) + len(r6))

def cmd_addr(kind, s, addrf):
    n = net(s.strip())
    if n is None:
        fail(2, 'garbage')
    if n.prefixlen < WIDE[n.version]:
        fail(3, 'wide')
    if kind == 'block':
        r = why_bad(n, own_load(addrf))
        if r == 'special':
            fail(5, 'special')
        if r:
            fail(6, r)
    elif any(n.subnet_of(m) for m in SPECIAL[n.version]):
        # Частные и служебные выкидываются из любого списка: исключать незачем.
        fail(5, 'special')
    print(n)

def cmd_own(addrf):
    # Адреса сервера для отпечатка: только те, что влияют на правила.
    # Частные и служебные (fe80 у veth, 172.17.0.1 у моста Docker) и так в
    # @allow — иначе каждый запуск контейнера пересобирал бы правила (К3-8/15).
    # Порядок — по числу, а не по локали (К3-11).
    own = own_load(addrf)
    for f in (4, 6):
        for a in sorted(set(own[f])):
            if not any(a in m for m in SPECIAL[f]):
                print(a)

def setdef(name, nets):
    t = 'ipv4_addr' if name.endswith('4') else 'ipv6_addr'
    r = ['\tset %s {' % name, '\t\ttype %s' % t, '\t\tflags interval', '\t\tauto-merge']
    items = [str(n) for n in nets]
    if items:
        r.append('\t\telements = {')
        for i in range(0, len(items), 6):
            tail = ',' if i + 6 < len(items) else ''
            r.append('\t\t\t' + ', '.join(items[i:i + 6]) + tail)
        r.append('\t\t}')
    r.append('\t}')
    return r

def vkchain(name, hook, lvl, prx=()):
    # Счёт выхода (статистика, уровень ≥ 1) — после @allow и до reject: то,
    # что пропускают исключения, не считается. Выход сервера со службами-
    # прокси (prx) считает цепочка vk_count (prxchain): выход прокси — это
    # клиенты VPN, как пересланное через сервер.
    cnt = 'out_fwd' if hook == 'forward' else 'out_srv'
    if lvl < 1:
        st = []
    elif hook == 'output' and prx:
        st = ['\t\tct state new ip daddr @vk4 jump vk_count',
              '\t\tct state new ip6 daddr @vk6 jump vk_count']
    else:
        st = ['\t\tct state new ip daddr @vk4 counter name "%s"' % cnt,
              '\t\tct state new ip6 daddr @vk6 counter name "%s"' % cnt]
    return ['\tchain %s {' % name,
            '\t\ttype filter hook %s priority 0; policy accept;' % hook,
            '\t\tip daddr @allow4 accept',
            '\t\tip6 daddr @allow6 accept'] + st + [
            '\t\tip daddr @vk4 meta l4proto tcp counter reject with tcp reset',
            '\t\tip daddr @vk4 counter reject with icmpx type admin-prohibited',
            '\t\tip6 daddr @vk6 meta l4proto tcp counter reject with tcp reset',
            '\t\tip6 daddr @vk6 counter reject with icmpx type admin-prohibited',
            '\t}']

# Службы-прокси (REVIEW-6 №6): соединение из cgroup службы (уровень 2 —
# system.slice/<юнит>.service; xray, запущенный x-ui, — в cgroup x-ui) — клиенты,
# остальное — сам сервер. Возврат (return) — в vk_output: запрет ВК для
# прокси тот же. Пакет без сокета — сервер, как до 1.2.4. Путь nft превращает
# в номер каталога при загрузке: каталога нет — nft не примет правила, и bash
# соберёт тот же уровень без служб.
PRXRX = re.compile(r'system\.slice/[A-Za-z0-9_.@-]{1,64}\.service')

def prxlist(s):
    r = []
    for x in s.split():
        if PRXRX.fullmatch(x) and x not in r and len(r) < 8:
            r.append(x)
    return r

def prxchain(prx):
    return (['\tchain vk_count {']
            + ['\t\tsocket cgroupv2 level 2 "%s" counter name "out_fwd" return' % p for p in prx]
            + ['\t\tcounter name "out_srv"', '\t}'])

# Статистика (1.2.4): уровни по тому, что умеют nft и ядро; bash пробует
# 3 → 0 через nft -c и грузит первый принятый.
#   3 — счётчики, наборы адресов со счётчиком в записи, порты, адрес+порт;
#   2 — счётчики и наборы адресов без счётчика; 1 — только счётчики;
#   0 — без статистики (правила как в 1.2.3).
# Наборы ограничены (size): полный набор не принимает новых записей, само
# правило и следующие за ним работают. v6 — по /64. Срок записи адреса —
# 35 суток (база в stats/ хранит дольше), порта и адрес+порта — 2 часа (такт —
# час): порт без попыток 2 часа уходит из набора, и полный набор освобождается
# сам, а не до пересборки таблицы (REVIEW-6 №7з). Снимок помнит счётчики только
# портов из последнего листинга: вернувшийся порт считается с нуля.
STAT_SETS = [('seen4', 'ipv4_addr', 65536, '35d', 2), ('seen6', 'ipv6_addr', 16384, '35d', 2),
             ('ports', 'inet_proto . inet_service', 8192, '2h', 3),
             ('pair4', 'ipv4_addr . inet_proto . inet_service', 32768, '2h', 3),
             ('pair6', 'ipv6_addr . inet_proto . inet_service', 16384, '2h', 3)]
V6NET = 'ip6 saddr & ffff:ffff:ffff:ffff::'

def statdefs(lvl, vk):
    r = ['\tcounter in4 {}', '\tcounter in6 {}']
    if vk:
        r += ['\tcounter out_fwd {}', '\tcounter out_srv {}']
    for name, typ, size, tmo, need in STAT_SETS:
        if lvl < need:
            continue
        r += ['\tset %s {' % name, '\t\ttype %s' % typ, '\t\tsize %d' % size,
              '\t\tflags dynamic%s' % (',timeout' if tmo else '')]
        if tmo:
            r.append('\t\ttimeout %s' % tmo)
        r.append('\t}')
    return r

def statchain(f, lvl):
    src = 'ip saddr' if f == 4 else V6NET
    c = ' counter' if lvl >= 3 else ''
    r = ['\tchain stat%d {' % f, '\t\tcounter name "in%d"' % f]
    if lvl >= 2:
        r.append('\t\tupdate @seen%d { %s%s }' % (f, src, c))
    if lvl >= 3:
        r += ['\t\tmeta l4proto { tcp, udp } update @ports { meta l4proto . th dport counter }',
              '\t\tmeta l4proto { tcp, udp } update @pair%d { %s . meta l4proto . th dport }' % (f, src)]
    return r + ['\t}']

def cmd_render(d, scan, vk, ports, addrf, dst, lvl='0', prx=''):
    lvl = int(lvl) if lvl in ('0', '1', '2', '3') else 0
    prx = prxlist(prx) if lvl >= 1 and vk == '1' else []
    own = own_load(addrf)
    P = sorted({int(p) for p in ports.split() if p.isdigit() and 0 < int(p) < 65536}) or [22]
    L = {k: load(d + '/lists/' + k) for k in ('scan4', 'scan6', 'vk4', 'vk6', 'tvk4', 'tvk6')}
    ex = load(d + '/exclude')
    bl = load(d + '/block')
    dropped = set()
    def clean(nets):
        res = []
        for n in nets:
            r = why_bad(n, own)
            if r:
                dropped.add('%s %s' % (n, r))
            else:
                res.append(n)
        return res
    allow = {f: SPECIAL[f] + [ipaddress.ip_network(a) for a in own[f]] for f in (4, 6)}
    for n in L['tvk4'] + L['tvk6'] + ex:
        allow[n.version].append(n)
    sets = [('allow4', collapse(allow[4])), ('allow6', collapse(allow[6]))]
    nets = 0
    # Сканеры выключены, а статистика есть — те же наборы, только для счёта.
    if scan == '1' or lvl >= 1:
        s4 = clean(L['scan4'] + [n for n in bl if n.version == 4])
        s6 = clean(L['scan6'] + [n for n in bl if n.version == 6])
        if scan == '1':
            nets = len(set(s4)) + len(set(s6))
        sets += [('scan4', collapse(s4)), ('scan6', collapse(s6))]
    if vk == '1':
        sets += [('vk4', collapse(clean(L['vk4']))), ('vk6', collapse(clean(L['vk6'])))]
    o = ['table %s {}' % TABLE, 'delete table %s' % TABLE]
    if scan == '1' or vk == '1' or lvl >= 1:
        o.append('table %s {' % TABLE)
        if lvl >= 1:
            o += statdefs(lvl, vk == '1')
        for name, v in sets:
            o += setdef(name, v)
        if lvl >= 1:
            o += statchain(4, lvl) + statchain(6, lvl)
        # Счёт попыток — новые соединения из списка сканеров (ct state new:
        # повтор SYN после drop — тоже попытка), после SSH и @allow: их не
        # считаем, как и не режем. Порядок SSH/allow/К3-5 тот же, что в 1.2.3.
        cnt = ['\t\tct state new ip saddr @scan4 jump stat4',
               '\t\tct state new ip6 saddr @scan6 jump stat6'] if lvl >= 1 else []
        if scan == '1':
            # Соединение, открытое сканером, режется и уже установленным
            # (К3-5): drop по direction original — ДО established, но после
            # SSH и @allow. Ответы на исходящие соединения сервера (и
            # пересланные через него) идут в направлении reply, их ICMP-ошибки
            # тоже (related reply) — проходят и принимаются established.
            # Последний drop — пакеты сканера без conntrack (invalid,
            # untracked: FIN/NULL/XMAS-сканы), как было до 1.2.1.
            o += ['\tchain incoming {',
                  '\t\ttype filter hook prerouting priority -150; policy accept;',
                  '\t\tiif "lo" accept',
                  '\t\ttcp dport { %s } accept' % ', '.join(str(p) for p in P),
                  '\t\tip saddr @allow4 accept',
                  '\t\tip6 saddr @allow6 accept'] + cnt + [
                  '\t\tip saddr @scan4 ct direction original counter drop',
                  '\t\tip6 saddr @scan6 ct direction original counter drop',
                  '\t\tct state established,related accept',
                  '\t\tip saddr @scan4 counter drop',
                  '\t\tip6 saddr @scan6 counter drop',
                  '\t}']
        elif lvl >= 1:
            # Сканеры выключены: сервер не блокирует, только считает.
            o += ['\tchain incoming {',
                  '\t\ttype filter hook prerouting priority -150; policy accept;',
                  '\t\tiif "lo" accept',
                  '\t\ttcp dport { %s } accept' % ', '.join(str(p) for p in P),
                  '\t\tip saddr @allow4 accept',
                  '\t\tip6 saddr @allow6 accept'] + cnt + ['\t}']
        if vk == '1':
            if prx:
                o += prxchain(prx)
            o += vkchain('vk_forward', 'forward', lvl) + vkchain('vk_output', 'output', lvl, prx)
        o.append('}')
    with open(dst, 'w') as fh:
        fh.write('\n'.join(o) + '\n')
    with open(d + '/dropped', 'w') as fh:
        fh.write(''.join(x + '\n' for x in sorted(dropped)))
    nx = len(set(L['tvk4'] + L['tvk6'] + ex)) + len(dropped)
    print('nets=%d nx=%d dropped=%d prx=%d' % (nets, nx, len(dropped), len(prx)))

cmd = sys.argv[1] if len(sys.argv) > 1 else ''
args = sys.argv[2:]
try:
    if cmd == 'list' and len(args) == 3:
        cmd_list(*args)
    elif cmd == 'within' and len(args) == 2:
        cmd_within(*args)
    elif cmd == 'hits' and len(args) >= 3:
        cmd_hits(*args)
    elif cmd == 'tvk' and len(args) == 6:
        cmd_tvk(*args)
    elif cmd == 'addr' and len(args) == 3:
        cmd_addr(*args)
    elif cmd == 'own' and len(args) == 1:
        cmd_own(*args)
    elif cmd == 'render' and len(args) in (6, 7, 8):
        cmd_render(*args)
    else:
        fail(64, 'usage')
except OSError as e:
    fail(1, 'io %s' % safe(str(e.strerror or '')))
PY
}

# ── статистика (1.2.4) ─────────────────────────────────────────────────
# stats/ — рядом со списками: каталог 0700, файлы 0600, запись атомарно
# (.tmp и rename). Переживает обновление goInstaller, пересборку правил,
# перезагрузку и --shield remove; стирают её --shield stats reset и удаление
# goInstaller. Снимок — в такт таймера и перед каждой пересборкой (при
# пересборке счётчики таблицы начинаются с нуля). Сети не трогает.
# Режимы python:
#   owners <blacklist_with_comments.txt> <куда> — сеть → AS и подпись (чужой
#       ввод: печатаемые, ≤ 60, без управляющих).
#   snap <stats> <листинг nft -a> <owners> <boot_id> <сейчас> — дельты к
#       прошлому снимку (счётчик меньше прошлого или другая таблица —
#       дельта = значение), корзины, база адресов, сводка для входа.
#   report <stats> <full|24h|7d|30d|all> <колонок> <ru|en> <сведения> <сейчас>
#   top <stats> <24h|7d|30d|all> <колонок> <ru|en> <сведения> <сейчас>
#   size <stats> <ru|en>
#   ui <stats> <сведения> <сейчас> — числа для экранов «Аркады», только чтение.
_shield_spy() {
    ( umask 077; exec python3 -I - "$@" ) <<'SPY'
import sys, os, io, re, time, ipaddress, unicodedata, bisect, hashlib
from array import array
LIMIT = 64 << 20
MAXADDR = 200000
if os.environ.get('GOINST_TEST') and (os.environ.get('GOINST_SHIELD_STATS_MAX') or '').isdigit():
    MAXADDR = max(1, int(os.environ['GOINST_SHIELD_STATS_MAX']))
KEEP = 40 * 86400
RXN = re.compile(r'-?[0-9]{1,19}')
LINK = 'github.com/C24Be/AS_Network_List'
LANG = 'ru'

def t(ru, en):
    return en if LANG == 'en' else ru

def ii(s, d=0):
    return int(s) if isinstance(s, str) and RXN.fullmatch(s) else d

def rd(path, limit=LIMIT):
    try:
        with open(path, 'rb') as fh:
            data = fh.read(limit + 1)
    except OSError:
        return []
    if len(data) > limit:
        return []
    return data.decode('utf-8', 'replace').splitlines()

def wr(path, rows):
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(''.join(r + '\n' for r in rows))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

def kvr(path):
    d = {}
    for l in rd(path, 1 << 20):
        k, s, v = l.partition('=')
        if s:
            d[k] = v
    return d

def label(s):
    # Подпись сети — чужой ввод: печатаемые буквы, цифры, знаки; без
    # управляющих, без широких (сломали бы колонки), '|' и '\' — '/'
    # (разделитель сводки и echo -e); не длиннее 60.
    out = []
    for c in s[:400]:
        cat = unicodedata.category(c)
        if c == '\t' or cat == 'Zs':
            c = ' '
        elif cat[0] not in 'LNP' and cat not in ('Sm', 'Sc'):
            continue
        elif unicodedata.east_asian_width(c) in ('W', 'F'):
            c = '?'
        if c in '|\\':
            c = '/'
        out.append(c)
    s = ' '.join(''.join(out).split())
    return s[:59].rstrip() + '…' if len(s) > 60 else s

def sdir(sd):
    if os.path.islink(sd):
        raise OSError(1, 'link')
    os.makedirs(sd, 0o700, exist_ok=True)
    os.chmod(sd, 0o700)

def hb(x):
    return x - x % 3600

def dk(x):
    return int(time.strftime('%Y%m%d', time.localtime(x)))

RX4 = re.compile(r'(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])')
RX6 = re.compile(r'[0-9a-f:]{2,39}')

def addr_ok(s):
    # Адрес в записи так, как его печатает nft. v4 — образцом (быстро: в
    # такте до 98 тыс. записей), v6 — ещё и через ipaddress.
    if RX4.fullmatch(s):
        return True
    if not RX6.fullmatch(s):
        return False
    try:
        return str(ipaddress.ip_address(s)) == s
    except ValueError:
        return False

def pport(proto, port):
    p = {'tcp': 'tcp', '6': 'tcp', 'udp': 'udp', '17': 'udp'}.get(proto)
    if p is None or not port.isdigit() or len(port) > 5 or int(port) > 65535:
        return None
    return '%d/%s' % (int(port), p)

# ── владельцы сетей ─────────────────────────────────────────────────────
def cmd_owners(path, dst):
    # blacklist_with_comments.txt: «# Networks announced by ASn» + «# AS-Name
    # (ORG): ИМЯ», под ними сети; «# Network name: ИМЯ»; «# NET-Name: сеть
    # ИМЯ …» и сеть следующей строкой; «---» — конец блока.
    res = {}
    cur = None
    asn = 0
    for raw in rd(path, 16 << 20):
        s = raw.strip()
        if not s:
            continue
        if s == '---':
            cur = None; asn = 0
            continue
        if s.startswith('#'):
            m = re.match(r'#\s*Networks announced by AS([0-9]{1,10})\b', s)
            if m:
                asn = int(m.group(1)) if int(m.group(1)) < 4294967296 else 0
                cur = (asn, '')
                continue
            m = re.match(r'#\s*AS-Name(?:\s*\([^)]*\))?\s*:\s*(.*)$', s)
            if m:
                cur = (asn, label(m.group(1)))
                continue
            m = re.match(r'#\s*Network name\s*:\s*(.*)$', s)
            if m:
                asn = 0; cur = (0, label(m.group(1)))
                continue
            m = re.match(r'#\s*NET-Name\s*:\s*(\S+)\s*(.*)$', s)
            if m:
                asn = 0
                # Хвост режется до регулярки: на длинной строке она
                # квадратичная (REVIEW-6 №2), а подпись всё равно ≤ 60.
                nm = re.sub(r'\(\s*\)|\b[A-Za-z0-9-]+-MNT\b', ' ', m.group(2)[:400])
                cur = (0, label(nm))
                n = onet(m.group(1))
                if n is not None:
                    res.setdefault(n, cur)
            continue
        if cur is None:
            continue
        n = onet(s.split('#', 1)[0].strip())
        if n is not None:
            res.setdefault(n, cur)
        if len(res) >= 200000:
            break
    rows = ['%s\t%d\t%s' % (n, a, nm) for n, (a, nm) in sorted(res.items(), key=lambda x: (x[0].version, x[0]))]
    wr(dst, rows)
    print(len(rows))

def onet(s):
    if len(s) > 49 or not re.fullmatch(r'[0-9A-Fa-f:.]+(/[0-9]{1,3})?', s):
        return None
    try:
        n = ipaddress.ip_network(s, strict=False)
    except ValueError:
        return None
    return n if n.prefixlen >= (8 if n.version == 4 else 16) else None

def v4int(s):
    # «a.b.c.d» → число; иное — None. Быстрее ipaddress: снимок ищет
    # владельца каждого нового адреса.
    p = s.split('.')
    if len(p) != 4 or not all(x.isdigit() and len(x) <= 3 for x in p):
        return None
    a, b, c, d = map(int, p)
    if a > 255 or b > 255 or c > 255 or d > 255:
        return None
    return a << 24 | b << 16 | c << 8 | d

class Owners:
    def __init__(self, path):
        self.tab = {4: {}, 6: {}}
        self.lab = []
        idx = {}
        labs = {}
        for l in lines(path, 32 << 20):
            p = l.split('\t')
            if len(p) != 3:
                continue
            net, _, pl = p[0].partition('/')
            v = v4int(net)
            if v is not None and pl.isdigit() and 8 <= int(pl) <= 32:
                ver, pl = 4, int(pl)
                key = v >> (32 - pl)
            else:
                n = onet(p[0])
                if n is None:
                    continue
                ver, pl = n.version, n.prefixlen
                key = int(n.network_address) >> ((32 if ver == 4 else 128) - pl)
            lb = labs.get(p[2])      # подписи повторяются: сеть AS — строкой каждая
            if lb is None:
                lb = label(p[2])
                if len(labs) < 65536:
                    labs[p[2]] = lb
            k = (ii(p[1]), lb)
            if k not in idx:
                idx[k] = len(self.lab); self.lab.append(k)
            self.tab[ver].setdefault(pl, {})[key] = idx[k]
        self.lens = {v: sorted(self.tab[v], reverse=True) for v in (4, 6)}

    def find(self, a):
        v = v4int(a)
        if v is not None:
            ver, bits = 4, 32
        else:
            try:
                x = ipaddress.ip_address(a)
            except ValueError:
                return None
            ver, bits, v = x.version, (32 if x.version == 4 else 128), int(x)
        T = self.tab[ver]
        for pl in self.lens[ver]:
            i = T[pl].get(v >> (bits - pl))
            if i is not None:
                return self.lab[i]
        return None

# ── снимок ──────────────────────────────────────────────────────────────
# Память и время (REVIEW-6 №1): листинг nft, база адресов и разбивки по
# владельцам читаются построчно и целиком в памяти не держатся. В памяти —
# только пришедшее из листинга за такт (до ~82 тыс. адресов seen и ~49 тыс.
# пар адрес+порт) и столбец «последний раз» базы (8 байт на адрес). Цель —
# ≤ 60 МБ и ≤ ~1 с ЦП на базе в MAXADDR адресов при полных наборах.
RXDUR = re.compile(r'(?:([0-9]{1,9})d)?(?:([0-9]{1,9})h)?(?:([0-9]{1,9})m)?(?:([0-9]{1,9})s)?(?:([0-9]{1,9})ms)?')
RXKW = re.compile(r' (?:timeout|expires|counter) ')
RXEL = re.compile(r' (timeout|expires) ([0-9a-z]{1,40})| counter packets ([0-9]{1,19}) bytes')
TMO = {}        # сроки наборов: их несколько, а записей — десятки тысяч

def dur(s):
    # «35d», «1h50m3s416ms» → секунды; иное — None.
    m = RXDUR.fullmatch(s)
    if not s or m is None:
        return None
    d, h, mi, se, ms = m.groups()
    return int(d or 0) * 86400 + int(h or 0) * 3600 + int(mi or 0) * 60 + int(se or 0) + int(ms or 0) / 1000

def elem(s):
    # Запись набора «ключ [timeout T] [expires E] [counter packets N bytes B]»
    # (порядок полей у nft 0.9.3 и 1.0.9 разный) → (части ключа, T, E, N).
    s = s.strip()
    m = RXKW.search(s)
    if m is None:
        return s.split(' . '), None, None, None
    tmo = exp = cnt = None
    for w, v, c in RXEL.findall(s, m.start()):
        if c:
            cnt = int(c)
        elif w == 'timeout':
            tmo = TMO.get(v)
            if tmo is None:
                tmo = dur(v)
                if len(TMO) < 64:
                    TMO[v] = tmo
        else:
            exp = dur(v)
    return s[:m.start()].split(' . '), tmo, exp, cnt

WANT = ('seen4', 'seen6', 'ports', 'pair4', 'pair6')
RXTAB = re.compile(r'table inet goinstall_shield \{\s*# handle ([0-9]{1,12})')
RXSET = re.compile(r'\tset ([A-Za-z0-9_]+) \{')
RXCNT = re.compile(r'\tcounter ([A-Za-z0-9_]+) \{')
RXPKT = re.compile(r'packets ([0-9]{1,19}) bytes')

def lopen(path, limit=LIMIT):
    # Файл для чтения построчно (строки — с '\n'); нет файла или больше
    # предела — пустой.
    try:
        fh = open(path, 'r', encoding='utf-8', errors='replace', newline='\n')
    except OSError:
        return io.StringIO()
    try:
        if os.fstat(fh.fileno()).st_size <= limit:
            return fh
    except OSError:
        pass
    fh.close()
    return io.StringIO()

def lines(path, limit=LIMIT):
    # Файл построчно, без '\n' и без загрузки целиком.
    with lopen(path, limit) as fh:
        for l in fh:
            yield l[:-1] if l.endswith('\n') else l

def parse(path, head):
    # Текстовый `nft -a list table` (JSON 0.9.3 не отдаёт счётчики записей),
    # построчно. head(номер таблицы) зовётся на заголовке и возвращает
    # put(набор, ключ, срок, осталось, счётчик): записи наборов WANT уходят
    # туда по одной, списком не копятся. → {'handle', 'cnt', 'sets', 'lvl'};
    # таблицы нет — None.
    L = None
    put = None
    inset = False
    cur = None      # набор из WANT, чьи записи читаем
    cn = None       # счётчик, чьё значение — на следующих строках
    buf = None      # хвост недочитанных записей «elements = { … }»
    def chunk(text, last):
        nonlocal buf
        ps = (buf + text).split(',')
        buf = None if last else ps.pop()
        for x in ps:
            if x and not x.isspace():
                put(cur, *elem(x))
    for l in lines(path):
        if L is None:
            m = RXTAB.match(l)
            if m:
                L = {'handle': m.group(1), 'cnt': {}, 'sets': set()}
                put = head(L['handle'])
            continue
        if buf is not None:
            if not buf and l.endswith(',') and l.count(',') == 1 and '}' not in l:
                put(cur, *elem(l[:-1]))     # запись на строке — так печатает nft
                continue
            e = l.find('}')
            chunk(l if e < 0 else l[:e], e >= 0)
            continue
        if inset:
            if l.startswith('\t}'):
                inset = False; cur = None
            elif cur is not None:
                e = l.find('elements = {')
                if e >= 0:
                    buf = ''
                    l = l[e + 12:]
                    e = l.find('}')
                    chunk(l if e < 0 else l[:e], e >= 0)
            continue
        if cn is not None:
            m = RXPKT.search(l)
            if m:
                L['cnt'][cn] = int(m.group(1))
            if m or '}' in l:
                cn = None
            continue
        m = RXSET.match(l)
        if m:
            inset = True
            cur = m.group(1) if m.group(1) in WANT else None
            if cur is not None:
                L['sets'].add(cur)
            continue
        m = RXCNT.match(l)
        if m:
            p = RXPKT.search(l, m.end())
            if p:
                L['cnt'][m.group(1)] = int(p.group(1))
            elif '}' not in l[m.end():]:
                cn = m.group(1)
    if L is not None:
        S = L['sets']
        L['lvl'] = 3 if 'ports' in S else 2 if 'seen4' in S else 1 if 'in4' in L['cnt'] else 0
    return L

def spread(total, a, b):
    # Дельта за [a, b] — по часовым корзинам пропорционально времени.
    if total <= 0:
        return {}
    if b <= a:
        return {hb(b): total}
    parts = []
    x = a
    while x < b:
        nx = min(hb(x) + 3600, b)
        parts.append((hb(x), nx - x)); x = nx
    span = b - a
    al = [total * w // span for _, w in parts]
    rem = total - sum(al)
    order = sorted(range(len(parts)), key=lambda i: -((total * parts[i][1]) % span))
    for i in order[:rem]:
        al[i] += 1
    return {parts[i][0]: al[i] for i in range(len(parts)) if al[i]}

def ld_rows(path, n):
    out = []
    for l in lines(path):
        p = l.split(' ')
        if len(p) == n:
            out.append(p)
    return out

def ports_str(c, k=3):
    return ','.join('%s:%d' % (p, n) for p, n in sorted(c.items(), key=lambda x: (-x[1], x[0]))[:k]) or '-'

def ports_parse(s):
    c = {}
    if s == '-':
        return c
    for x in s.split(','):
        p, _, n = x.rpartition(':')
        if p and re.fullmatch(r'[0-9]{1,5}/(tcp|udp)', p) and RXN.fullmatch(n):
            c[p] = c.get(p, 0) + int(n)
    return c

class Addrs:
    # База адресов для чтения (отчёт, сводка, экраны): «первый раз»,
    # «последний раз», попытки и владелец — столбцами array('q'), 32 байта
    # на адрес. values() — кортежи (first, last, att, oid): r[0], r[1], r[3]
    # те же, что у прежнего словаря адрес → строка.
    def __init__(self, path):
        F = self.f = array('q'); L = self.l = array('q'); A = self.a = array('q'); O = self.o = array('q')
        with lopen(path) as fh:
            for l in fh:
                p = l.split(' ', 5)
                if len(p) != 6 or p[5].count(' ') != 4:
                    continue
                try:
                    f, la, at, o = int(p[1]), int(p[2]), int(p[3]), int(p[4])
                    F.append(f); L.append(la); A.append(at); O.append(o)
                except (ValueError, OverflowError):
                    n = len(O)
                    del F[n:], L[n:], A[n:]
    def __len__(self):
        return len(self.l)
    def values(self):
        return zip(self.f, self.l, self.a, self.o)
    def since(self, lo):
        # Адресов, бывших не раньше lo.
        return sum(1 for x in self.l if x >= lo)
    def after(self, t):
        return sum(1 for x in self.l if x > t)
    def newrep(self, lo):
        # (новые, повторные) за период с lo: впервые с lo / раньше.
        nw = sum(1 for f, x in zip(self.f, self.l) if x >= lo and f >= lo)
        return nw, self.since(lo) - nw
    def per_owner(self, since):
        na = {}
        for x, o in zip(self.l, self.o):
            if x >= since:
                na[o] = na.get(o, 0) + 1
        return na

def kvl(d):
    return ['%s=%s' % (k, v) for k, v in d.items()]

def topen(path, mode='w'):
    fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, mode, encoding='utf-8') if mode == 'w' else os.fdopen(fd, mode)

def wtmp(path, rows):
    with topen(path) as fh:
        for r in rows:
            fh.write(r + '\n')

# Запись снимка — двухфазная (REVIEW-6 №3): сначала все файлы в .tmp, затем
# журнал commit со списком (одной заменой), затем .tmp на место (meta —
# последней), журнал стирается. Упали посреди замен — следующий снимок
# доводит их по журналу (recover); упали до журнала — .tmp выбрасываются,
# остаётся прежнее. Дельта не считается дважды и не теряется.
FILES = ('hours', 'days', 'ports', 'ports_all', 'pprev', 'addrs', 'own_h', 'own_d', 'own_all', 'owners',
         'gone', 'summary', 'meta')

class St:
    def __init__(self, sd):
        self.sd = sd
    def p(self, n):
        return os.path.join(self.sd, n)
    def owners(self):
        o = {0: (0, '')}
        for l in lines(self.p('owners')):
            p = l.split(' ', 2)
            if len(p) == 3 and p[0].isdigit():
                o[int(p[0])] = (ii(p[1]), label(p[2]))
        return o
    def hours(self):
        H = {}
        for p in ld_rows(self.p('hours'), 7):
            H[ii(p[0])] = [ii(x) for x in p[1:]]
        return H
    def days(self):
        D = {}
        for p in ld_rows(self.p('days'), 7):
            D[ii(p[0])] = [ii(x) for x in p[1:]]
        return D
    def addrs(self):
        return Addrs(self.p('addrs'))
    def ownagg(self, name, lo=None):
        # (час или день, владелец) → [попыток, адресов, последний раз, порты];
        # lo — только строки не раньше.
        R = {}
        for l in lines(self.p(name)):
            p = l.split(' ')
            if len(p) == 6:
                k = ii(p[0])
                if lo is None or k >= lo:
                    R[(k, ii(p[1]))] = [ii(p[2]), ii(p[3]), ii(p[4]), ports_parse(p[5])]
        return R
    def ownsum(self, name, lo, ports=True):
        # Владелец → [попыток, адресов, последний раз, порты] по строкам не
        # раньше lo, построчно.
        R = {}
        for l in lines(self.p(name)):
            p = l.split(' ')
            if len(p) != 6 or ii(p[0]) < lo:
                continue
            o = ii(p[1])
            x = R.get(o)
            if x is None:
                x = R[o] = [0, 0, 0, {}]
            x[0] += ii(p[2]); x[1] += ii(p[3]); x[2] = max(x[2], ii(p[4]))
            if ports:
                for pp, n in ports_parse(p[5]).items():
                    x[3][pp] = x[3].get(pp, 0) + n
        return R
    def commit(self, names):
        wr(self.p('commit'), names)
        self.finish(names)
    def finish(self, names):
        die = ii(os.environ.get('GOINST_SHIELD_STATS_DIE', ''), -1) if os.environ.get('GOINST_TEST') else -1
        for i, n in enumerate(names):
            if i == die:
                os._exit(9)     # набор: «убит посреди замен»
            t = self.p(n) + '.tmp'
            if os.path.lexists(t):
                os.replace(t, self.p(n))
        os.unlink(self.p('commit'))
    def recover(self):
        if os.path.lexists(self.p('commit')):
            self.finish([n for n in rd(self.p('commit'), 1 << 12) if n in FILES])
            return
        for t in [self.p(n) + '.tmp' for n in FILES + ('commit',)] + [self.p('addrs.new')]:
            if os.path.lexists(t) and not os.path.isdir(t):
                os.unlink(t)

class Gone:
    # Адреса, вытесненные из базы по пределу (REVIEW-6 №7ж): вернулся — не
    # «новый», «всего адресов» не растёт второй раз. Фильтр Блума 1 МиБ,
    # 4 хеша: ложное «уже был» — около 0,25 % при 500 тыс. записей; больше —
    # фильтр начинается заново.
    BITS = 1 << 23
    CAP = 500000
    def __init__(self, path, n):
        self.path = path
        self.n = n
        self.b = None
        self.dirty = False
    def load(self):
        if self.b is None:
            data = b''
            if self.n > 0:
                try:
                    with open(self.path, 'rb') as fh:
                        data = fh.read(self.BITS // 8 + 1)
                except OSError:
                    pass
            if len(data) == self.BITS // 8:
                self.b = bytearray(data)
            else:
                self.b = bytearray(self.BITS // 8); self.n = 0
        return self.b
    def idx(self, ad):
        v = int.from_bytes(hashlib.blake2b(ad.encode(), digest_size=8).digest(), 'little')
        h1 = v & 0xffffffff
        h2 = (v >> 32) | 1
        return [(h1 + i * h2) % self.BITS for i in range(4)]
    def has(self, ad):
        if self.n <= 0:
            return False
        b = self.load()
        return self.n > 0 and all(b[i >> 3] >> (i & 7) & 1 for i in self.idx(ad))
    def add(self, ad):
        b = self.load()
        if self.n >= self.CAP:
            b[:] = bytes(len(b)); self.n = 0
        for i in self.idx(ad):
            b[i >> 3] |= 1 << (i & 7)
        self.n += 1
        self.dirty = True

MASK = (1 << 36) - 1

def cmd_snap(sd, live, ownf, boot, now):
    now = ii(now)
    if not 0 < now <= MASK:
        now = int(time.time())
    if not re.fullmatch(r'[0-9A-Za-z-]{1,64}', boot):
        boot = 'x'
    sdir(sd)
    S = St(sd)
    S.recover()
    meta = kvr(S.p('meta'))
    started = ii(meta.get('started', ''), 0) or now
    prev = ii(meta.get('snap', ''), 0)
    gen = ii(meta.get('gen', ''), 0)
    base = meta.get('base') == '1'
    meta['started'] = started
    # Записи наборов — сразу в компактном виде, числа упакованы в одно
    # целое (последний раз — младшие 36 бит):
    #   hits: адрес → (счётчик + 1) << 36 | последний раз (0 — без счётчика);
    #   pad, pval: адрес+порт — адрес и номер порта << 36 | последний раз;
    #   ppl: номер порта → «443/tcp»; pc: порт → счётчик.
    hits = {}
    pad = []
    pval = array('q')
    ppl = []
    ppi = {}
    pc = {}
    ctx = {}
    def head(handle):
        key = '%s:%s' % (boot, handle)
        same = prev > 0 and key == meta.get('key')
        ctx.update(key=key, same=same)
        def put(name, k, tmo, exp, cnt):
            if name == 'ports':
                if len(k) == 2 and cnt is not None:
                    pp = pport(k[0], k[1])
                    if pp:
                        pc[pp] = pc.get(pp, 0) + cnt
                return
            if base:
                return
            last = int(now - (tmo - exp)) if tmo is not None and exp is not None else now
            last = min(max(last, 0), now)
            if same and last <= prev:
                return
            if name[1] == 'e':
                if len(k) == 1 and addr_ok(k[0]):
                    hits[k[0]] = (0 if cnt is None else cnt + 1) << 36 | last
            elif len(k) == 3 and addr_ok(k[0]):
                pp = pport(k[1], k[2])
                if pp is not None:
                    i = ppi.get(pp)
                    if i is None:
                        i = ppi[pp] = len(ppl); ppl.append(pp)
                    pad.append(k[0]); pval.append(i << 36 | last)
        return put
    L = parse(live, head) if live else None
    if L is None:
        # Таблицы не видно (снята, nft не ответил) — снимок не делается:
        # ключ и время прошлого снимка прежние, та же таблица потом
        # досчитается без двойного счёта. Обнуление без таблицы — новая
        # таблица считается целиком.
        if base:
            meta.pop('base', None)
            meta['key'] = ''
        wtmp(S.p('summary'), kvl(summary(S, meta, now)))
        wtmp(S.p('meta'), kvl(meta))
        S.commit(['summary', 'meta'])
        return
    if base:
        # Обнуление — запомнить, с какого места считать: всё, что в таблице
        # до него, не в счёт.
        meta.pop('base', None)
        gen += 1
        meta.update(snap=now, key=ctx['key'], gen=gen, lvl=L['lvl'])
        for c in ('in4', 'in6', 'out_fwd', 'out_srv'):
            if c in L['cnt']:
                meta['c_' + c] = L['cnt'][c]
        wtmp(S.p('pprev'), ['%s %d %d' % (pp, cnt, gen) for pp, cnt in pc.items()])
        wtmp(S.p('summary'), kvl(summary(S, meta, now)))
        wtmp(S.p('meta'), kvl(meta))
        S.commit(['pprev', 'summary', 'meta'])
        return
    key = ctx['key']
    same = ctx['same']
    if not same:
        gen += 1
    a = prev if same else max(prev, now - 3600)
    a = max(a, now - KEEP)
    if a >= now:
        a = now - 1
    # Счётчики: меньше прошлого или другая таблица — дельта = значение.
    dl = {}
    for c in ('in4', 'in6', 'out_fwd', 'out_srv'):
        cur = L['cnt'].get(c)
        if cur is None:
            meta.pop('c_' + c, None)
            continue
        pv = ii(meta.get('c_' + c, ''), -1) if same else -1
        dl[c] = cur - pv if 0 <= pv <= cur else cur
        meta['c_' + c] = cur
    din = dl.get('in4', 0) + dl.get('in6', 0)
    dfw = dl.get('out_fwd', 0)
    dsr = dl.get('out_srv', 0)
    H = S.hours()
    D = S.days()
    dkc = {}
    def dkx(x):
        # День по местному времени; пояса кратны 15 минутам — кеш по четвертям часа.
        q = x // 900
        v = dkc.get(q)
        if v is None:
            v = dkc[q] = dk(x)
        return v
    def hrow(h):
        return H.setdefault(h, [0] * 6)
    def drow(d):
        return D.setdefault(d, [0] * 6)
    for col, v in ((0, din), (4, dfw), (5, dsr)):
        for h, x in spread(v, a, now).items():
            hrow(h)[col] += x
            drow(dkx(h))[col] += x
    meta['tin'] = ii(meta.get('tin', ''), 0) + din
    meta['tfw'] = ii(meta.get('tfw', ''), 0) + dfw
    meta['tsr'] = ii(meta.get('tsr', ''), 0) + dsr
    # Владельцы сетей.
    O = S.owners()
    oid = {v: k for k, v in O.items()}
    ownv = ''
    try:
        st = os.stat(ownf)
        ownv = '%d.%d' % (st.st_size, int(st.st_mtime))
    except OSError:
        pass
    reown = ownv != meta.get('ownv', '')
    own = None
    def owner(addr):
        nonlocal own
        if own is None:
            own = Owners(ownf)
        k = own.find(addr) or (0, '')
        if k not in oid:
            oid[k] = max(O) + 1; O[oid[k]] = k
        return oid[k]
    # Разбивка по владельцам: в памяти — прибавка этого такта (час/день ×
    # владелец); прежние строки own_h/own_d сливаются с ней построчно.
    dOH = {}
    dOD = {}
    OA = {}
    for p in ld_rows(S.p('own_all'), 5):
        OA[ii(p[0])] = [ii(p[1]), ii(p[2]), ii(p[3]), ports_parse(p[4])]
    def oagg(R, k):
        x = R.get(k)
        if x is None:
            x = R[k] = [0, 0, 0, None]
        return x
    def oall(o):
        x = OA.get(o)
        if x is None:
            x = OA[o] = [0, 0, 0, {}]
        return x
    naddr = ii(meta.get('naddr', ''), 0)
    gone = Gone(S.p('gone'), ii(meta.get('gone_n', ''), 0))
    evt = ii(meta.get('gone_t', ''), 0)
    def hit(row, isnew, last, cnt):
        # row: [first, last, att, oid, cnt, gen, lasth, lastd, lastport]
        d = 0
        if cnt is not None:
            d = cnt - row[4] if (row[5] == gen and 0 <= row[4] <= cnt) else cnt
            row[4] = cnt; row[5] = gen
        row[2] += d
        row[1] = max(row[1], last)
        h = hb(last); dd = dkx(last)
        o = row[3]
        x = oagg(dOH, (h, o)); x[0] += d; x[2] = max(x[2], last)
        y = oagg(dOD, (dd, o)); y[0] += d; y[2] = max(y[2], last)
        z = oall(o)
        z[0] += d; z[2] = max(z[2], last)
        if isnew:
            z[1] += 1
        if row[6] != h:
            hr = hrow(h); hr[1] += 1; hr[2 if isnew else 3] += 1; row[6] = h; x[1] += 1
        if row[7] != dd:
            dr = drow(dd); dr[1] += 1; dr[2 if isnew else 3] += 1; row[7] = dd; y[1] += 1
    def hv(v):
        c = (v >> 36) - 1
        return v & MASK, (None if c < 0 else c)
    # Последний порт адреса — по самой свежей паре (lastp: адрес → упакованная
    # пара; после прохода по базе — ~владелец, если адрес в базе).
    lastp = {}
    for ad, v in zip(pad, pval):
        x = lastp.get(ad)
        if x is None or v & MASK >= x & MASK:
            lastp[ad] = v
    # Проход по базе: строки без перемен — как есть, адреса из листинга — с
    # новыми числами, затем новые адреса. По ходу — числа для сводки и
    # «последний раз» каждой строки (предел базы).
    upto = ii(kvr(S.p('seen')).get('upto', ''), 0)
    lo24 = now - 86400
    lasts = array('q')
    na24 = {}
    away = 0
    used = set()
    def fmt_row(ad, row):
        return '%s %d %d %d %d %d %d %d %d %s\n' % (ad, row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8])
    nw = S.p('addrs.new')
    fd = os.open(nw, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as out, lopen(S.p('addrs')) as src:
        for l in src:
            p = l.split(' ', 5)
            if len(p) != 6 or p[5].count(' ') != 4:
                continue
            ad = p[0]
            h = hits.pop(ad, None)
            lp = lastp.get(ad)
            if h is None and lp is None:
                try:
                    la = int(p[2]); o = int(p[4])
                except ValueError:
                    continue
                out.write(l if l[-1] == '\n' else l + '\n')
            else:
                q = p[5].rstrip('\n').split(' ')
                try:
                    row = [int(p[1]), int(p[2]), int(p[3]), int(p[4]), int(q[0]), int(q[1]), int(q[2]), int(q[3]), q[4]]
                except ValueError:
                    continue
                if h is not None:
                    if reown:
                        row[3] = owner(ad)
                    hit(row, False, *hv(h))
                if lp is not None:
                    row[8] = ppl[lp >> 36]
                    lastp[ad] = ~row[3]
                out.write(fmt_row(ad, row))
                la = row[1]; o = row[3]
            lasts.append(la)
            used.add(o)
            if la >= lo24:
                na24[o] = na24.get(o, 0) + 1
            if la > upto:
                away += 1
        for ad, v in hits.items():
            # Вернулся вытесненный по пределу — не новый: первый раз не
            # позже последнего вытеснения, в часах и днях — повторный.
            last, cnt = hv(v)
            back = gone.has(ad)
            o = owner(ad)
            row = [min(last, evt) if back else last, last, 0, o, 0, gen, 0, 0, '-']
            if not back:
                naddr += 1
            hit(row, not back, last, cnt)
            lp = lastp.get(ad)
            if lp is not None:
                row[8] = ppl[lp >> 36]
                lastp[ad] = ~o
            out.write(fmt_row(ad, row))
            lasts.append(last)
            used.add(o)
            if last >= lo24:
                na24[o] = na24.get(o, 0) + 1
            if last > upto:
                away += 1
    hits = None
    meta['naddr'] = naddr
    if reown:
        meta['ownv'] = ownv
    # Адрес + порт: чей порт у владельца.
    for ad, v in zip(pad, pval):
        x = lastp[ad]
        if x < 0:
            o = ~x
        else:
            o = owner(ad); lastp[ad] = ~o
        pp = ppl[v >> 36]; last = v & MASK
        for R, k in ((dOH, (hb(last), o)), (dOD, (dkx(last), o))):
            x = oagg(R, k)
            if x[3] is None:
                x[3] = {}
            x[3][pp] = x[3].get(pp, 0) + 1
        c = oall(o)[3]; c[pp] = c.get(pp, 0) + 1
    pad = pval = lastp = None
    # Предел базы: лишние — по давности последнего раза, вытесненные — в
    # фильтр Gone. С запасом 5 %: иначе каждый такт на пределе переписывал
    # бы базу второй раз.
    n = len(lasts)
    if n <= MAXADDR:
        os.replace(nw, S.p('addrs') + '.tmp')
    else:
        keep = MAXADDR - MAXADDR // 20
        s = sorted(lasts)
        thr = s[n - keep]
        tie = keep - (n - bisect.bisect_right(s, thr))
        s = None
        na24 = {}
        away = 0
        used = set()
        with topen(S.p('addrs')) as out:
            for l in lines(nw):
                p = l.split(' ', 5)
                if len(p) != 6:
                    continue
                la = int(p[2])
                if la > thr or (la == thr and tie > 0):
                    if la == thr:
                        tie -= 1
                    out.write(l + '\n')
                    o = int(p[4])
                    used.add(o)
                    if la >= lo24:
                        na24[o] = na24.get(o, 0) + 1
                    if la > upto:
                        away += 1
                else:
                    gone.add(p[0])
                    evt = max(evt, la)
        os.unlink(nw)
        meta['gone_t'] = evt
        meta['gone_n'] = gone.n
    lasts = None
    # Порты: попытки по порту за такт.
    pv = {}
    for p in ld_rows(S.p('pprev'), 3):
        pv[p[0]] = (ii(p[1]), ii(p[2]))
    PH = {}
    for p in ld_rows(S.p('ports'), 3):
        PH.setdefault(ii(p[0]), {})[p[1]] = ii(p[2])
    PA = {}
    for p in ld_rows(S.p('ports_all'), 2):
        PA[p[0]] = ii(p[1])
    mid = hb((a + now) // 2)
    for pp, cnt in pc.items():
        q = pv.get(pp)
        d = cnt - q[0] if q and q[1] == gen and 0 <= q[0] <= cnt else cnt
        if d > 0:
            c = PH.setdefault(mid, {}); c[pp] = c.get(pp, 0) + d
            PA[pp] = PA.get(pp, 0) + d
    names = ['addrs']
    if 'ports' in L['sets']:
        wtmp(S.p('pprev'), ['%s %d %d' % (pp, cnt, gen) for pp, cnt in pc.items()])
        names.append('pprev')
    # Сроки и пределы.
    lim = hb(now) - KEEP
    wtmp(S.p('hours'), ['%d %s' % (h, ' '.join(map(str, v))) for h, v in sorted(H.items()) if h >= lim])
    wtmp(S.p('days'), ['%d %s' % (d, ' '.join(map(str, v))) for d, v in sorted(D.items())])
    rows = []
    for h, c in sorted(PH.items()):
        if h >= lim:
            rows += ['%d %s %d' % (h, pp, n) for pp, n in sorted(c.items(), key=lambda x: (-x[1], x[0]))[:20]]
    wtmp(S.p('ports'), rows)
    wtmp(S.p('ports_all'), ['%s %d' % (pp, n) for pp, n in sorted(PA.items(), key=lambda x: (-x[1], x[0]))[:1000]])
    names += ['hours', 'days', 'ports', 'ports_all']
    # own_h (двое суток) и own_d (KEEP): прежние строки (по порядку ключей)
    # и прибавка такта — слиянием. Попутно — владельцы за сутки для сводки.
    oh24 = {}
    def merge(name, dR, cut, lo):
        ks = sorted(dR)
        j = 0
        def emit(fh, k, v):
            fh.write('%d %d %d %d %d %s\n' % (k[0], k[1], v[0], v[1], v[2], ports_str(v[3] or {})))
        def note(k, v):
            used.add(k[1])
            if lo is not None and k[0] >= lo:
                g = oh24.get(k[1])
                if g is None:
                    g = oh24[k[1]] = [0, 0, 0, {}]
                g[0] += v[0]; g[1] += v[1]; g[2] = max(g[2], v[2])
        with topen(S.p(name)) as fh:
            for l in lines(S.p(name)):
                p = l.split(' ')
                if len(p) != 6:
                    continue
                k = (ii(p[0]), ii(p[1]))
                if k[0] < cut:
                    continue
                while j < len(ks) and ks[j] < k:
                    v = dR.pop(ks[j], None)
                    if v is not None and ks[j][0] >= cut:
                        emit(fh, ks[j], v); note(ks[j], v)
                    j += 1
                x = dR.pop(k, None)
                v = [ii(p[2]), ii(p[3]), ii(p[4]), None]
                if x is not None:
                    c = ports_parse(p[5])
                    for pp, m in (x[3] or {}).items():
                        c[pp] = c.get(pp, 0) + m
                    v = [v[0] + x[0], v[1] + x[1], max(v[2], x[2]), c]
                    emit(fh, k, v)
                else:
                    fh.write(l + '\n')
                note(k, v)
            for k in ks[j:]:
                v = dR.pop(k, None)
                if v is not None and k[0] >= cut:
                    emit(fh, k, v); note(k, v)
    merge('own_h', dOH, hb(now) - 2 * 86400, h24(now)[0])
    merge('own_d', dOD, dk(now - KEEP), None)
    dOH = dOD = None
    used |= set(OA)
    wtmp(S.p('own_all'), ['%d %d %d %d %s' % (k, v[0], v[1], v[2], ports_str(v[3])) for k, v in sorted(OA.items())])
    wtmp(S.p('owners'), ['%d %d %s' % (k, v[0], v[1]) for k, v in sorted(O.items()) if k and k in used])
    names += ['own_h', 'own_d', 'own_all', 'owners']
    if gone.dirty:
        with topen(S.p('gone'), 'wb') as fh:
            fh.write(gone.b)
        names.append('gone')
    meta.update(snap=now, key=key, gen=gen, lvl=L['lvl'])
    wtmp(S.p('summary'), kvl(summary(S, meta, now, H, (na24, away, oh24, O, upto))))
    wtmp(S.p('meta'), kvl(meta))
    S.commit(names + ['summary', 'meta'])

def median(v):
    s = sorted(v)
    return s[(len(s) - 1) // 2] if s else 0

def h24(now):
    return [hb(now) - 3600 * i for i in range(23, -1, -1)]

def spike(hs, vin, started):
    # Всплеск: час ≥ 2× медианы и не меньше 20. Медиана — по полным часам
    # с начала счёта (часы до него — не нули, а «нет данных»; первая дельта
    # ложится на час до started, и тот час неполный) и только когда таких
    # часов не меньше 6: иначе на свежем сервере любой час был бы всплеском.
    if not vin:
        return None
    ok = [v for h, v in zip(hs, vin) if h >= hb(started)]
    if len(ok) < 6:
        return None
    md = max(1, median(ok))
    mx = max(vin)
    if mx < 20 or mx < 2 * md:
        return None
    return vin.index(mx), (mx * 20 + md) // (2 * md), mx

def top(S, A, aggs, since, n, O=None, na=None):
    # aggs: {oid: [att, addrs, last, ports]}; адресов за период — из базы
    # (Addrs или словарь строк) либо готовые na.
    O = O or S.owners()
    if na is None and since > 0:
        if hasattr(A, 'per_owner'):
            na = A.per_owner(since)
        else:
            na = {}
            for r in A.values():
                if r[1] >= since:
                    na[r[3]] = na.get(r[3], 0) + 1
    res = []
    for o, v in aggs.items():
        if o not in O:
            continue
        nad = na.get(o, v[1]) if since > 0 else v[1]
        pt = sorted(v[3].items(), key=lambda x: (-x[1], x[0]))
        res.append((v[0], nad, o, O[o][0], O[o][1], v[2], pt[0][0] if pt else ''))
    res.sort(key=lambda x: (-x[0], -x[1], x[2]))
    return res[:n]

def summary(S, meta, now, H=None, pre=None):
    # Сводка для входа — на время последнего настоящего снимка (snap), а не
    # на время вызова: без таблицы числа не становятся «за сутки до сейчас»
    # (REVIEW-6 №4). pre — посчитанное снимком по ходу (адресов за сутки по
    # владельцам, «пока вас не было», владельцы за сутки, владельцы, отметка
    # показа); без него — построчно из файлов. → словарь для файла summary.
    T = ii(str(meta.get('snap', '')), 0) or now
    H = S.hours() if H is None else H
    hs = h24(T)
    if pre is None:
        upto = ii(kvr(S.p('seen')).get('upto', ''), 0)
        na24 = {}
        away = 0
        for l in lines(S.p('addrs')):
            p = l.split(' ', 5)
            if len(p) != 6:
                continue
            try:
                la = int(p[2]); o = int(p[4])
            except ValueError:
                continue
            if la >= T - 86400:
                na24[o] = na24.get(o, 0) + 1
            if la > upto:
                away += 1
        oh24 = S.ownsum('own_h', hs[0], False)
        O = S.owners()
    else:
        na24, away, oh24, O, upto = pre
    vin = [H.get(h, [0] * 6)[0] for h in hs]
    sm = {'snap': T, 'lvl': meta.get('lvl', 0), 'started': meta.get('started', now),
          'tin': meta.get('tin', 0), 'tfw': meta.get('tfw', 0), 'tsr': meta.get('tsr', 0),
          'naddr': meta.get('naddr', 0), 'd24_in': sum(vin),
          'd24_fw': sum(H.get(h, [0] * 6)[4] for h in hs), 'd24_sr': sum(H.get(h, [0] * 6)[5] for h in hs)}
    for i, x in enumerate(top(S, None, oh24, T - 86400, 3, O, na24), 1):
        sm['t24_%d' % i] = '%d|%s|%d|%d' % (x[3], x[4], x[0], x[1])
    sp = spike(hs, vin, ii(str(meta.get('started', '')), 0) or T)
    if sp:
        sm.update(spike_h=hs[sp[0]], spike_x10=sp[1], spike_n=sp[2])
    sm['away_ref'] = upto
    sm['away_n'] = away
    return sm

# ── вывод ───────────────────────────────────────────────────────────────
def padR(s, n):
    return s[:n - 1] + '…' if len(s) > n else s + ' ' * (n - len(s))

def padL(s, n):
    return s[:n - 1] + '…' if len(s) > n else ' ' * (n - len(s)) + s

def pl(n, a, b, c, e1, en):
    if LANG == 'en':
        return e1 if n == 1 else en
    d, h = n % 10, n % 100
    return a if d == 1 and h != 11 else b if 2 <= d <= 4 and (h < 12 or h > 14) else c

def wrap(text, w, keep):
    words = []
    for x in text.split(' '):
        if x == '·' and words:
            words[-1] += ' ·'
        else:
            words.append(x)
    out, line = [], ''
    for wd in words:
        if not line:
            line = wd
        elif wd not in keep and len(line) + 1 + len(wd) <= w:
            line += ' ' + wd
        else:
            out.append(line); line = wd
    if line:
        out.append(line)
    return out

WD = {'ru': ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'], 'en': ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']}
MON = {'ru': ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'],
       'en': ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']}
PER = {'24h': 86400, '7d': 7 * 86400, '30d': 30 * 86400, 'all': 0}

def fmt(x, f):
    return time.strftime(f, time.localtime(x))

def footer(C):
    P = [t('Списки сетей — открытый проект AS_Network_List · ' + LINK + ' (BSD-2)',
           'Network lists: open project AS_Network_List · ' + LINK + ' (BSD-2)'),
         t('Спасибо автору C24Be за данные и идею. Защита в goInstaller — anten-ka.',
           'Thanks to C24Be for the data and the idea. goInstaller protection — anten-ka.')]
    return ['# ' + l for p in P for l in wrap(p, C - 2, [LINK])]

def perlab(p):
    return {'24h': t('сутки', '24h'), '7d': t('7 дней', '7d'), '30d': t('месяц', '30d'), 'all': t('всего', 'all')}[p]

def topkey(p):
    return {'24h': t('топ24ч', 'top24h'), '7d': t('топ7д', 'top7d'), '30d': t('топ30д', 'top30d'), 'all': t('топвсё', 'topall')}[p]

def noLabel():
    return t('без подписи в списке', 'no label in the list')

def presumed():
    return t('предположительно, по названию сети', 'presumably, by network name')

class Data:
    def __init__(self, sd, now):
        self.S = St(sd)
        self.now = now
        self.meta = kvr(self.S.p('meta'))
        self.H = self.S.hours()
        self.D = self.S.days()
        self.A = self.S.addrs()
        self.O = self.S.owners()
        self.seen = kvr(self.S.p('seen'))
    def win(self, p):
        return self.now - PER[p] if PER[p] else 0
    def sums(self, p, cols):
        if p == 'all':
            return [sum(v[c] for v in self.D.values()) for c in cols]
        lo = hb(self.now) - PER[p] + 3600
        return [sum(v[c] for h, v in self.H.items() if h >= lo) for c in cols]
    def naddr(self, p):
        if p == 'all':
            return ii(self.meta.get('naddr', ''), 0)
        return self.A.since(self.now - PER[p])
    def away(self):
        at = ii(self.seen.get('at', ''), 0) or ii(self.meta.get('started', ''), 0)
        upto = ii(self.seen.get('upto', ''), 0)
        tin = ii(self.meta.get('tin', ''), 0) - ii(self.seen.get('cin', ''), 0)
        tfw = ii(self.meta.get('tfw', ''), 0) - ii(self.seen.get('cfw', ''), 0)
        tsr = ii(self.meta.get('tsr', ''), 0) - ii(self.seen.get('csr', ''), 0)
        tin, tfw, tsr = [max(x, 0) for x in (tin, tfw, tsr)]
        return at, tin, self.A.after(upto), tfw, tsr
    def owners_for(self, p):
        if p == '24h':
            ag = self.S.ownsum('own_h', hb(self.now) - 23 * 3600)
        elif p == 'all':
            ag = {}
            for l in ld_rows(self.S.p('own_all'), 5):
                ag[ii(l[0])] = [ii(l[1]), ii(l[2]), ii(l[3]), ports_parse(l[4])]
            return top(self.S, self.A, ag, 0, 30, self.O)
        else:
            ag = self.S.ownsum('own_d', dk(self.now - PER[p] + 86400))
        return top(self.S, self.A, ag, self.win(p), 30, self.O)
    def ports_for(self, p):
        c = {}
        if p == 'all':
            for l in ld_rows(self.S.p('ports_all'), 2):
                c[l[0]] = ii(l[1])
        else:
            lo = hb(self.now) - PER[p] + 3600
            for l in ld_rows(self.S.p('ports'), 3):
                if ii(l[0]) >= lo:
                    c[l[1]] = c.get(l[1], 0) + ii(l[2])
        return sorted(c.items(), key=lambda x: (-x[1], x[0]))

def lvl_note(lv):
    if lv >= 3:
        return None
    if lv == 2:
        return t('неполные: без портов и попыток по адресам — nft или ядро умеют не всё',
                 'partial: no ports or attempts per address — nft or the kernel cannot do everything')
    if lv == 1:
        return t('неполные: только число попыток — nft или ядро умеют не всё',
                 'partial: attempt counts only — nft or the kernel cannot do everything')
    return t('нет данных — nft или ядро не умеют счётчиков', 'no data — nft or the kernel cannot count')

def info_read(path):
    i = {'lab': {}}
    for l in rd(path, 1 << 20):
        k, s, v = l.partition('=')
        if not s:
            continue
        if k.startswith('lab '):
            pp = k[4:]
            if re.fullmatch(r'[0-9]{1,5}/(tcp|udp)', pp):
                i['lab'][pp] = label(v)[:24]
        else:
            i[k] = v
    return i

def snapt(X, now):
    # Время в шапке отчёта — последнего снимка: отчёт читает только его
    # (К5-7, стенд 03.11: в 20:28 «вход 0», а в ядре уже 28). Снимка нет — сейчас.
    return (ii(X.meta.get('snap', ''), 0) if X.meta else 0) or now

def cmd_report(sd, per, cols, lang, infof, now):
    global LANG
    LANG = 'en' if lang == 'en' else 'ru'
    now = ii(now)
    C = max(40, min(ii(cols, 80) or 80, 200))
    n = C < 60
    I = info_read(infof)
    host = label(I.get('host', ''))[:40] or '?'
    R = []
    def T(x):
        x = x.rstrip()
        if x or (R and R[-1]):
            R.append(x[:C - 1] + '…' if len(x) > C else x)
    kv = lambda k, v: T(padR(k, 11) + v)
    def line(k, l, Lw, cl, name=None):
        T(padR(k, 7) + padR(l, Lw) + ''.join(padL('' if c is None else str(c), 9) for c in cl) + ('  ' + name if name is not None else ''))
    X = Data(sd, now)
    hd = [t('защита от сканеров', 'scanner protection'), host + ' · ' + fmt(snapt(X, now), '%d.%m.%Y %H:%M')]
    if n:
        T('# goInstaller · ' + hd[0]); T('# ' + hd[1])
    else:
        T('# goInstaller · ' + hd[0] + ' · ' + hd[1])
    on = I.get('scan') == '1'
    vk = I.get('vk') == '1'
    # «Только считает» — по уровню правил сейчас (stl); нет его — по данным.
    sl = ii(I.get('stl', ''), -1)
    if sl < 0:
        sl = ii(X.meta.get('lvl', ''), 0) if X.meta else 0
    kv(t('вход', 'in'), t('вкл · сканеры останавливаются', 'on · scanners are stopped') if on
       else t('выкл · только считает', 'off · counting only') if sl >= 1 else t('выкл · не блокирует', 'off · not blocking'))
    kv(t('выход', 'out'), t('вкл · утечка IP к ВК не выпускается', 'on · IP leak to VK is blocked') if vk else t('выкл · защита от утечки IP не работает', 'off · IP leak protection is not working'))
    ld = ii(I.get('date', ''), 0)
    nn = ii(I.get('nets', ''), 0)
    kv(t('список', 'list'), 'AS_Network_List ' + t('от ', 'of ') + (fmt(ld, '%d.%m.%Y') if ld else '—') + ' · ' + str(nn)
       + t(' сетей · исключено ', ' networks · excluded ') + str(ii(I.get('nx', ''), 0)))
    kv('ipv6', t('считается по /64', 'counted per /64'))
    if not X.meta:
        kv(t('данные', 'data'), t('нет данных — статистика ещё не собрана', 'no data — no statistics collected yet'))
        T('')
        R.extend(footer(C))
        print('\n'.join(R))
        return
    lv = ii(X.meta.get('lvl', ''), 0)
    if lvl_note(lv):
        kv(t('данные', 'data'), lvl_note(lv))
    st = ii(X.meta.get('started', ''), 0) or now
    st0 = st - 3600       # первая дельта — за час до started; раньше — «—», а не 0
    pers = ['24h', '7d', '30d', 'all']
    at, ain, aad, afw, asr = X.away()
    sl = t('с ', 'since ') + fmt(at, '%d.%m %H:%M')
    T('')
    line('#', t('период', 'period'), 18, [t('попыток', 'attempts'), t('адресов', 'address')])
    line(t('вход', 'in'), sl, 18, [ain, aad])
    for p in pers:
        line(t('вход', 'in'), perlab(p), 18, [X.sums(p, [0])[0], X.naddr(p)])
    T('')
    line('#', t('период', 'period'), 18, [t('всего', 'total'), t('клиенты', 'clients'), t('сервер', 'server')])
    line(t('выход', 'out'), sl, 18, [afw + asr, afw, asr])
    for p in pers:
        fw, sr = X.sums(p, [4, 5])
        line(t('выход', 'out'), perlab(p), 18, [fw + sr, fw, sr])
    # Выход служб-прокси nft отличает не везде (REVIEW-6 №6): не отличил —
    # он в колонке «сервер», и подпись это говорит. Ключ — «выход», как у
    # строк таблицы: каркас ключей sh-f остаётся макетным.
    if vk and lv >= 1:
        pu = [x for x in I.get('prx', '').split(',') if re.fullmatch(r'[A-Za-z0-9_.@-]{1,64}', x)][:8]
        if pu:
            T(padR(t('выход', 'out'), 7) + t('клиенты — VPN и прокси: ', 'clients — VPN and proxies: ') + ', '.join(pu))
        elif I.get('prxa'):
            T(padR(t('выход', 'out'), 7) + t('сервер — сервер и прокси на нём', 'server — the server and proxies on it'))
        else:
            # Служб-прокси нет — о прокси ни слова (К5-17).
            T(padR(t('выход', 'out'), 7) + t('сервер — сам сервер', 'server — the server itself'))
    T('')
    show = ['24h', '7d'] if per == 'full' else [per]
    if per in ('full', '7d', '30d'):
        nd = 30 if per == '30d' else 7
        line('#', t('дата', 'date'), 14, [t('вход', 'in'), t('выход', 'out')])
        for i in range(nd - 1, -1, -1):
            x = now - 86400 * i
            v = X.D.get(dk(x), [0] * 6)
            line(t('день', 'day'), fmt(x, '%d.%m') + ' ' + WD[LANG][time.localtime(x).tm_wday], 14,
                 ['—', '—'] if dk(x) < dk(st0) else [v[0], v[4] + v[5]])
        T('')
    if per == 'all':
        mm = {}
        for d, v in X.D.items():
            k = d // 100
            x = mm.setdefault(k, [0, 0]); x[0] += v[0]; x[1] += v[4] + v[5]
        line('#', t('месяц', 'month'), 14, [t('вход', 'in'), t('выход', 'out')])
        for k in sorted(mm):
            line(t('мес', 'month'), MON[LANG][k % 100 - 1] + ' ' + str(k // 100), 14, mm[k])
        T('')
    if per in ('full', '24h'):
        line('#', t('время', 'time'), 14, [t('вход', 'in'), t('выход', 'out')])
        hs = h24(now)
        vin = []
        for h in hs:
            v = X.H.get(h, [0] * 6) if h >= hb(st0) else [0] * 6
            vin.append(v[0])
            line(t('час', 'hour'), fmt(h, '%H:%M'), 14, ['—', '—'] if h < hb(st0) else [v[0], v[4] + v[5]])
        T('')
        # Час до начала счёта пиком не бывает; попыток не было — пика нет,
        # а не первый час окна с 0 (К5-7).
        mx = max(vin)
        i = vin.index(mx)
        kv(t('пик', 'peak'), fmt(hs[i], '%H:%M') + '–' + fmt(hs[i] + 3600, '%H:%M') + ' · ' + str(mx) if mx else '—')
        sp = spike(hs, vin, st)
        if sp:
            x10 = sp[1]
            kv(t('всплеск', 'spike'), '×%d%s%d' % (x10 // 10, t(',', '.'), x10 % 10) + t(' к медиане часа', ' vs hourly median'))
        else:
            kv(t('всплеск', 'spike'), t('нет', 'none'))
    ap = '24h' if per == 'full' else per
    if per != 'all':
        lo = now - PER[ap]
        nw, rp = X.A.newrep(lo)
        kv(t('адреса', 'addresses'), t('новые ', 'new ') + str(nw) + t(' · повторные ', ' · repeat ') + str(rp))
    T('')
    pp = X.ports_for(ap)
    if lv >= 3:
        line('#', t('порт', 'port'), 14, [perlab(ap)], t('чей', 'whose'))
        for q, v in pp[:6]:
            line(t('порт', 'port'), q, 14, [v], I['lab'].get(q, t('свободен', 'free')))
        T('')
    net = t('сеть — ', 'network — ') + presumed()
    if n:
        line('#', 'AS', 10, [t('попыток', 'attempts'), t('адресов', 'address')]); T('#   ' + net)
    else:
        line('#', 'AS', 10, [t('попыток', 'attempts'), t('адресов', 'address')], net)
    for p in show:
        for x in X.owners_for(p)[:5]:
            nm = x[4] or noLabel()
            asn = 'AS%d' % x[3] if x[3] else '—'
            at_ = x[0] if lv >= 3 else '—'
            if n:
                line(topkey(p), asn, 10, [at_, x[1]]); T('   ' + nm)
            else:
                line(topkey(p), asn, 10, [at_, x[1]], nm)
    T('')
    R.extend(footer(C))
    print('\n'.join(R))

def cmd_top(sd, per, cols, lang, infof, now):
    global LANG
    LANG = 'en' if lang == 'en' else 'ru'
    now = ii(now)
    C = max(40, min(ii(cols, 80) or 80, 200))
    I = info_read(infof)
    host = label(I.get('host', ''))[:40] or '?'
    X = Data(sd, now)
    R = []
    def T(x):
        R.append(x.rstrip())
    T('# goInstaller · ' + t('топ-30 сканеров', 'top 30 scanners') + ' · ' + perlab(per) + ' · ' + host + ' · ' + fmt(snapt(X, now), '%d.%m.%Y %H:%M'))
    if not X.meta:
        T(t('нет данных — статистика ещё не собрана', 'no data — no statistics collected yet'))
    else:
        lv = ii(X.meta.get('lvl', ''), 0)
        if lvl_note(lv):
            T('# ' + lvl_note(lv))
        T(padR('#', 4) + padR('AS', 10) + padL(t('попыток', 'attempts'), 9) + padL(t('адресов', 'address'), 9) + '  '
          + padR(t('последний раз', 'last seen'), 15) + padR(t('порт', 'port'), 10) + t('сеть — ', 'network — ') + presumed())
        rows = X.owners_for(per)
        for i, x in enumerate(rows, 1):
            T(padR(str(i), 4) + padR('AS%d' % x[3] if x[3] else '—', 10) + padL(str(x[0]) if lv >= 3 else '—', 9) + padL(str(x[1]), 9) + '  '
              + padR(fmt(x[5], '%d.%m %H:%M') if x[5] else '—', 15) + padR(x[6] or '—', 10) + (x[4] or noLabel()))
        if not rows:
            T(t('за период сканеров не было', 'no scanners over the period'))
    T('')
    R.extend(footer(C))
    print('\n'.join(R))

def cmd_size(sd, lang):
    global LANG
    LANG = 'en' if lang == 'en' else 'ru'
    S = St(sd)
    tot = 0
    try:
        for e in os.scandir(sd):
            if e.is_file(follow_symlinks=False):
                tot += e.stat(follow_symlinks=False).st_size
    except OSError:
        pass
    meta = kvr(S.p('meta'))
    rows = sum(1 for _ in lines(S.p('addrs')))
    print('bytes=%d' % tot)
    print('started=%d' % ii(meta.get('started', ''), 0))
    print('rows=%d' % rows)
    print('naddr=%d' % ii(meta.get('naddr', ''), 0))
    print('max=%d' % MAXADDR)

def cmd_ui(sd, infof, now):
    # Модель для экранов «Аркады» (2-й шаг): только чтение, готовые числа
    # строками «вид|поля…»; подпись сети — последним полем и через label()
    # (в ней нет '|'). Нет meta — одна строка «none».
    now = ii(now)
    X = Data(sd, now)
    I = info_read(infof)
    R = []
    def P(*a):
        R.append('|'.join(str(x) for x in a))
    if not X.meta:
        print('none')
        return
    lv = ii(X.meta.get('lvl', ''), 0)
    st = ii(X.meta.get('started', ''), 0) or now
    st0 = st - 3600
    tot = 0
    try:
        for e in os.scandir(sd):
            if e.is_file(follow_symlinks=False):
                tot += e.stat(follow_symlinks=False).st_size
    except OSError:
        pass
    a, b = time.localtime(st), time.localtime(now)
    nd = (time.mktime((b.tm_year, b.tm_mon, b.tm_mday, 12, 0, 0, 0, 0, -1))
          - time.mktime((a.tm_year, a.tm_mon, a.tm_mday, 12, 0, 0, 0, 0, -1)))
    nd = max(1, int(round(nd / 86400.0)) + 1)
    # Нет lvl в meta (сразу после обнуления) — «-»: экраны покажут «нет данных».
    P('g', lv if 'lvl' in X.meta else '-', fmt(st, '%d.%m.%Y'), fmt(st, '%H:%M'), nd, tot, X.naddr('all'))
    for p in ('24h', '7d', '30d', 'all'):
        fi = X.sums(p, [0])[0]
        fw, sr = X.sums(p, [4, 5])
        nw = rp = '-'
        if p != 'all':
            lo = now - PER[p]
            nw = sum(1 for r in X.A.values() if r[1] >= lo and r[0] >= lo)
            rp = sum(1 for r in X.A.values() if r[1] >= lo and r[0] < lo)
        P('per', p, fi, X.naddr(p), fw + sr, nw, rp)
    hs = h24(now)
    vin = []
    for h in hs:
        v = X.H.get(h, [0] * 6) if h >= hb(st0) else [0] * 6
        vin.append(v[0])
        P('h', fmt(h, '%H'), v[0], v[4] + v[5])
    mx = max(vin)
    i = vin.index(mx)
    # Правило всплеска одно для всех периодов: пик ≥ 2× медианы (точно, не
    # по округлённому ×) и не меньше 20. Нет всплеска — и × не показывает 2,0
    # (×1,97 округлилось бы в «всплеска нет · пик ×2,0»): тогда ×1,9.
    sp = spike(hs, vin, st)
    if sp:
        x10, s = sp[1], 1
    else:
        ok = [v for h, v in zip(hs, vin) if h >= hb(st)]
        md = max(1, median(ok)) if len(ok) >= 6 else 0
        x10, s = ((mx * 20 + md) // (2 * md) if md else -1), 0
        if md and mx < 2 * md and x10 >= 20:
            x10 = 19
    P('pk', '24h', mx, x10, s, fmt(hs[i], '%H'))
    dd = []
    for k in range(29, -1, -1):
        x = now - 86400 * k
        lt = time.localtime(x)
        v = X.D.get(dk(x), [0] * 6) if dk(x) >= dk(st0) else [0] * 6
        dd.append((lt, v[0], v[4] + v[5], dk(x) >= dk(st0)))
        P('d', fmt(x, '%d'), fmt(x, '%m'), (lt.tm_wday + 1) % 7, v[0], v[4] + v[5])
    for p, g in (('7d', dd[23:]), ('30d', dd)):
        ok = [q[1] for q in g if q[3]]
        vv = [q[1] for q in g]
        m = max(vv)
        j = vv.index(m)
        md = max(1, median(ok)) if len(ok) >= 3 else 0
        x10 = (m * 20 + md) // (2 * md) if md else -1
        s = 1 if md and m >= 2 * md and m >= 20 else 0
        if md and m < 2 * md and x10 >= 20:
            x10 = 19
        lt = g[j][0]
        P('pk', p, m, x10, s,
          time.strftime('%d|%m', lt), (lt.tm_wday + 1) % 7)
    mm = {}
    for d, v in X.D.items():
        x = mm.setdefault(d // 100, [0, 0]); x[0] += v[0]; x[1] += v[4] + v[5]
    ks = sorted(mm)[-12:] or [int(fmt(now, '%Y%m'))]
    for k in ks:
        v = mm.get(k, [0, 0])
        P('m', k % 100, k // 100, v[0], v[1])
    m = max([mm.get(k, [0, 0])[0] for k in ks])
    k = [q for q in ks if mm.get(q, [0, 0])[0] == m][0]
    P('pk', 'all', m, 0, 0, k % 100, k // 100)
    for p in ('24h', '7d', '30d', 'all'):
        if lv >= 3:
            for q, v in X.ports_for(p)[:4]:
                P('pt', p, q, v, I['lab'].get(q, ''))
        for j, x in enumerate(X.owners_for(p)[:30], 1):
            P('t', p, j, x[0], x[1], x[3], fmt(x[5], '%d.%m') if x[5] else '-',
              fmt(x[5], '%H:%M') if x[5] else '-', x[6] or '-', x[4])
    print('\n'.join(R))

cmd = sys.argv[1] if len(sys.argv) > 1 else ''
args = sys.argv[2:]
try:
    if cmd == 'owners' and len(args) == 2:
        cmd_owners(*args)
    elif cmd == 'snap' and len(args) == 5:
        cmd_snap(*args)
    elif cmd == 'report' and len(args) == 6 and args[1] in ('full', '24h', '7d', '30d', 'all'):
        cmd_report(*args)
    elif cmd == 'top' and len(args) == 6 and args[1] in ('24h', '7d', '30d', 'all'):
        cmd_top(*args)
    elif cmd == 'size' and len(args) == 2:
        cmd_size(*args)
    elif cmd == 'ui' and len(args) == 3:
        cmd_ui(*args)
    else:
        sys.stdout.write('usage\n'); sys.exit(64)
except OSError as e:
    sys.stdout.write('io %s\n' % ''.join(c if c.isascii() and c.isalnum() else '?' for c in str(e.strerror or '')[:40]))
    sys.exit(1)
except Exception as e:
    sys.stdout.write('err %s\n' % type(e).__name__[:40])
    sys.exit(1)
SPY
}
_shield_stats_paths() { _shield_paths; SHIELD_STATS="$SHIELD_DIR/stats"; }
_shield_bootid() {
    local b=""
    if [ -n "${GOINST_TEST:-}" ]; then b="${GOINST_SHIELD_BOOTID:-test}"
    else read -r b 2>/dev/null < /proc/sys/kernel/random/boot_id || b=""; fi
    printf '%s' "${b:-x}"
}
# Снимок: листинг таблицы (nft -a: номер таблицы отличает пересобранную) →
# python. Ошибка — строка в журнал, только когда она сменилась; защите
# снимок не мешает никогда (rc 0).
shield_stats_snap() {
    local live out rc e0
    _shield_stats_paths
    [ -d "$SHIELD_DIR" ] || return 0
    # stats/ — ссылка: через неё не пишем (не наш каталог). Строка в журнал —
    # один раз, пока ссылка на месте (stlink в status).
    if [ -L "$SHIELD_STATS" ]; then
        [ "$(_shield_get "$SHIELD_DIR/status" stlink)" = 1 ] && return 0
        shield_log "$(bi "статистика не пишется: ${SHIELD_STATS} — ссылка, а не каталог; удалите ссылку" "statistics are not written: ${SHIELD_STATS} is a link, not a directory; remove the link")"
        _shield_set "$SHIELD_DIR/status" "stlink=1"
        return 0
    fi
    [ "$(_shield_get "$SHIELD_DIR/status" stlink)" = 1 ] && _shield_set "$SHIELD_DIR/status" "stlink="
    command -v python3 >/dev/null 2>&1 || return 0
    { ( umask 077; mkdir -p "$SHIELD_STATS" ) && chmod 700 "$SHIELD_STATS"; } 2>/dev/null || return 0
    live="$SHIELD_STATS/.live"
    rm -f "$live"
    if _shield_have_nft; then
        ( umask 077; _shield_nft -a list table inet "$SHIELD_TABLE" > "$live" ) 2>/dev/null || rm -f "$live"
    fi
    out=$(_shield_spy snap "$SHIELD_STATS" "$live" "$SHIELD_DIR/lists/owners" "$(_shield_bootid)" "$(_shield_now)" 2>&1); rc=$?
    rm -f "$live"
    e0=$(_shield_get "$SHIELD_STATS/.err" e) || e0=""
    if [ "$rc" -ne 0 ]; then
        out=$(_shield_clean "${out:-${rc}}")
        [ "$out" = "$e0" ] || shield_log "$(bi "статистика не записалась: ${out}" "statistics were not written: ${out}")"
        _shield_set "$SHIELD_STATS/.err" "e=${out}"
    elif [ -n "$e0" ]; then
        rm -f "$SHIELD_STATS/.err"
        shield_log "$(bi "статистика снова пишется" "statistics are written again")"
    fi
    return 0
}
# В такт таймера — не чаще раза в 5 минут: такт зовёт и слежка за SSH.
_shield_stats_tick() {
    local s
    _shield_stats_paths
    s=$(_shield_num "$SHIELD_STATS/meta" snap)
    [ $(( $(_shield_now) - s )) -ge 300 ] || return 0
    shield_stats_snap
}
_shield_has_stats() { _shield_stats_paths; [ -f "$SHIELD_STATS/meta" ]; }
# Сведения для отчёта: режимы, список, имя сервера, чей порт (SSH — по
# настройкам sshd, прочие — по слушателю; нет слушателя — «свободен»).
_shield_stats_info() {  # _shield_stats_info <куда>
    local f="$1" scan vk n x h p l pr ad po pc pi who px pa=""
    local -A seen=()
    scan=$(_shield_get "$SHIELD_DIR/settings" scan) || scan=0
    vk=$(_shield_get "$SHIELD_DIR/settings" vk) || vk=0
    shield_installed || { scan=0; vk=0; }
    n=$(_shield_num "$SHIELD_DIR/status" nets)
    [ "$n" -gt 0 ] || n=$(( $(_shield_num "$SHIELD_DIR/lists/meta" n4) + $(_shield_num "$SHIELD_DIR/lists/meta" n6) ))
    x=$(_shield_num "$SHIELD_DIR/status" nx)
    if [ -n "${GOINST_TEST:-}" ]; then h="${GOINST_SHIELD_HOST:-test}"; else h=$(hostname -s 2>/dev/null) || h=""; fi
    {
        printf 'scan=%s\nvk=%s\ndate=%s\nnets=%s\nnx=%s\nhost=%s\n' "$scan" "$vk" "$(_shield_num "$SHIELD_DIR/lists/meta" date)" "$n" "$x" "${h:-server}"
        # Службы-прокси, чей выход считается клиентами (shield_apply); пусто —
        # nft их не отличает, выход прокси — в «сервере».
        px=$(_shield_get "$SHIELD_DIR/status" prx 2>/dev/null) || px=""
        # nft службы не отличил (prx пуст): идут ли они вообще — «сервер и
        # прокси на нём» или «сам сервер» (К5-17, стенд 03.11).
        if [ "$vk" = 1 ] && [ -z "$px" ] && command -v systemctl >/dev/null 2>&1; then
            for p in $SHIELD_PROXY_UNITS; do
                [ "$(systemctl show -p ActiveState --value "$p.service" 2>/dev/null)" = active ] && pa+="$p,"
            done
        fi
        printf 'prx=%s\nprxa=%s\nstl=%s\n' "$px" "${pa%,}" "$(_shield_get "$SHIELD_DIR/status" stl 2>/dev/null)"
        for p in $(shield_ssh_ports); do
            case "$p" in ''|*[!0-9]*) continue ;; esac
            printf 'lab %s/tcp=SSH\n' "$p"; seen["$p/tcp"]=1
        done
        scan_listeners
        while IFS='|' read -r pr ad po pc pi; do
            case "$pr" in tcp|udp) ;; *) continue ;; esac
            case "$po" in ''|*[!0-9]*) continue ;; esac
            [ -z "${seen[$po/$pr]:-}" ] || continue
            seen["$po/$pr"]=1
            l=$(port_holders "$pr" "$po" | head -n 1)
            IFS='|' read -r who _ l _ <<<"$l"
            # Ничей порт контейнера — «docker:имя»: подпись — имя контейнера.
            case "$l" in ''|system) l="${who#*:}" ;; *) l=$(prod_name "$l") ;; esac
            printf 'lab %s/%s=%s\n' "$po" "$pr" "${l//[$'\n\r']/}"
        done <<<"$LISTENERS"
    } > "$f" 2>/dev/null
}
# goinstall --shield stats [24h|7d|30d|all] | top [период] | size | reset [--yes]
# Коды: 0 — показано или сделано, 1 — не вышло, 3 — статистики нет, 64 —
# неверная команда (и reset без терминала без --yes).
shield_stats_cli() {
    local a="${1:-}" b="${2:-}" yes="" x rc cols info out
    for x in "$@"; do case "$x" in --yes|-y) yes=1 ;; esac; done
    case "$a" in --yes|-y) a="" ;; esac
    case "$b" in --yes|-y) b="" ;; esac
    _shield_stats_paths
    case "$a" in ''|24h|7d|30d|all|top|size|reset) ;; *) usage; return 64 ;; esac
    case "$a:$b" in top:|top:24h|top:7d|top:30d|top:all|reset:|size:|*:) ;; *) usage; return 64 ;; esac
    command -v python3 >/dev/null 2>&1 || { err "$(bi "Нет python3 — статистику не прочесть." "python3 is missing — cannot read the statistics.")"; return 1; }
    if [ "$a" = reset ]; then
        _shield_has_stats || { say "$(bi "Статистики нет — обнулять нечего." "There are no statistics — nothing to reset.")"; return 0; }
        if [ -z "$yes" ]; then
            if [ ! -t 0 ]; then err "$(bi "Без терминала спросить некого: goinstall --shield stats reset --yes" "No terminal to ask: goinstall --shield stats reset --yes")"; return 64; fi
            if shield_installed; then
                confirm "$(bi "Обнулить статистику защиты? Счётчики, графики и топ сотрутся; списки сетей и правила защиты останутся." "Reset the protection statistics? Counters, charts and the top are erased; network lists and protection rules stay.")" n || { say "$(bi "Оставил как есть." "Left as is.")"; return 0; }
            else
                # Защита уже снята (remove): осталась только статистика.
                confirm "$(bi "Защиты от сканеров уже нет. Удалить оставшуюся статистику (${SHIELD_STATS})?" "Scanner protection is already removed. Delete the statistics left behind (${SHIELD_STATS})?")" n || { say "$(bi "Оставил как есть." "Left as is.")"; return 0; }
            fi
        fi
        shield_stats_reset || { err "$(bi "Не обнулилось: ${SHIELD_ERR}" "Did not reset: ${SHIELD_ERR}")"; return 1; }
        if [ -n "${SHIELD_GONE:-}" ]; then ok "$(bi "Статистика удалена: ${SHIELD_STATS}." "The statistics are deleted: ${SHIELD_STATS}.")"; return 0; fi
        ok "$(bi "Статистика обнулена. Списки сетей и правила защиты не менялись." "The statistics are reset. Network lists and protection rules are unchanged.")"
        return 0
    fi
    if ! _shield_has_stats && ! shield_installed; then
        say "$(bi "Защита от сканеров не стоит, статистики нет." "Scanner protection is not installed, there are no statistics.")"; return 3
    fi
    cols=80
    if [ -t 1 ]; then cols=$(tput cols 2>/dev/null) || cols=80; fi
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    if [ "$a" = size ]; then
        out=$(_shield_spy size "$SHIELD_STATS" "$LANG_CODE" 2>/dev/null) || { err "$(bi "Статистику не прочесть." "Cannot read the statistics.")"; return 1; }
        _shield_stats_size_print "$out"
        return 0
    fi
    info=$(mktemp "${TMPDIR:-/tmp}/goinst-stats.XXXXXX") || return 1
    with_scan_cache _shield_stats_info "$info"
    if [ "$a" = top ]; then out=$(_shield_spy top "$SHIELD_STATS" "${b:-24h}" "$cols" "$LANG_CODE" "$info" "$(_shield_now)" 2>/dev/null); rc=$?
    else out=$(_shield_spy report "$SHIELD_STATS" "${a:-full}" "$cols" "$LANG_CODE" "$info" "$(_shield_now)" 2>/dev/null); rc=$?; fi
    rm -f "$info"
    [ "$rc" -eq 0 ] || { err "$(bi "Статистику не прочесть: $(_shield_clean "$out")" "Cannot read the statistics: $(_shield_clean "$out")")"; return 1; }
    printf '%s\n' "$out"
    return 0
}
_shield_stats_size_print() {
    local k v by=0 st=0 rows=0 na=0 mx=0 kb
    while IFS='=' read -r k v; do
        case "$v" in ''|*[!0-9]*) continue ;; esac
        case "$k" in bytes) by="$v" ;; started) st="$v" ;; rows) rows="$v" ;; naddr) na="$v" ;; max) mx="$v" ;; esac
    done <<<"$1"
    kb=$(( (by + 1023) / 1024 ))
    printf '%s\n' "$(pad_to "$(bi "на диске" "on disk")" 22)${kb} $(bi "КБ" "KB")"
    printf '%s\n' "$(pad_to "$(bi "собирается с" "collected since")" 22)$([ "$st" -gt 0 ] && printf '%(%d.%m.%Y %H:%M)T' "$st" || printf '—')"
    printf '%s\n' "$(pad_to "$(bi "адресов в базе" "addresses in the base")" 22)${rows} $(bi "из" "of") ${mx}"
    printf '%s\n' "$(pad_to "$(bi "адресов всего" "addresses in total")" 22)${na}"
    printf '%s\n' "$(pad_to "$(bi "каталог" "directory")" 22)${SHIELD_STATS}"
}
# Обнулить: файлы статистики стереть, отметка base=1 — следующий снимок
# только запоминает, с какого места считать (таблица при этом пересобирается,
# если защита стоит: счётчики ядра тоже с нуля). Защиты нет (сняли remove) —
# каталог stats/ удаляется целиком: считать больше нечего (SHIELD_GONE=1).
shield_stats_reset() {
    local f
    SHIELD_ERR=""
    _shield_stats_paths
    if [ -L "$SHIELD_STATS" ]; then
        SHIELD_ERR=$(bi "${SHIELD_STATS} — ссылка, а не каталог; через ссылку не удаляю — удалите её сами" "${SHIELD_STATS} is a link, not a directory; I do not delete through a link — remove it yourself")
        return 1
    fi
    _shield_lock_say || { SHIELD_ERR=$(bi "защита занята" "the protection is busy"); return 1; }
    # rm -r: внутри бывают каталоги (недописанный .tmp); ссылка внутри
    # удаляется сама, без того, на что она указывает.
    for f in "$SHIELD_STATS"/* "$SHIELD_STATS"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        rm -rf -- "$f"
    done
    SHIELD_GONE=""
    if ! shield_installed; then
        if ! rmdir "$SHIELD_STATS" 2>/dev/null && [ -e "$SHIELD_STATS" ]; then
            SHIELD_ERR=$(bi "каталог ${SHIELD_STATS} не удалился" "${SHIELD_STATS} was not removed"); _shield_unlock; return 1
        fi
        SHIELD_GONE=1; _shield_unlock; return 0
    fi
    ( umask 077; mkdir -p "$SHIELD_STATS" && printf 'started=%s\nbase=1\n' "$(_shield_now)" > "$SHIELD_STATS/meta" ) 2>/dev/null
    chmod 700 "$SHIELD_STATS" 2>/dev/null; chmod 600 "$SHIELD_STATS/meta" 2>/dev/null
    if shield_installed && [ -f "$SHIELD_DIR/shield.nft" ]; then
        shield_apply || shield_log "$(bi "после обнуления статистики правила не пересобрались: ${SHIELD_ERR}" "the rules were not rebuilt after the statistics reset: ${SHIELD_ERR}")"
        SHIELD_ERR=""
    fi
    shield_log "$(bi "статистика обнулена" "the statistics are reset")"
    _shield_unlock
    return 0
}

# Ключ=значение в своих файлах: читаем сами, не source.
_shield_get() {  # _shield_get <файл> <ключ>
    local l
    [ -r "$1" ] || return 1
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in "$2="*) printf '%s' "${l#*=}"; return 0 ;; esac
    done < "$1"
    return 1
}
_shield_num() { local v; v=$(_shield_get "$1" "$2") || v=0; case "$v" in ''|*[!0-9]*) v=0 ;; esac; printf '%s' "$v"; }
_shield_set() {  # _shield_set <файл> <ключ=значение…> — заменить эти ключи, прочее оставить
    local f="$1" l kv k skip
    shift
    local -a out=()
    if [ -r "$f" ]; then
        while IFS= read -r l || [ -n "$l" ]; do
            skip=0
            for kv in "$@"; do k="${kv%%=*}"; case "$l" in "$k="*) skip=1 ;; esac; done
            [ "$skip" = 1 ] || out+=("$l")
        done < "$f"
    fi
    for kv in "$@"; do kv="${kv//$'\n'/ }"; out+=("${kv//$'\r'/ }"); done
    printf '%s\n' "${out[@]}" > "$f.tmp" 2>/dev/null && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}
# Текст из чужого вывода (ответ nft, ошибка) — одной строкой, без
# управляющих символов: в журнал и на экран (echo -e не должен ничего раскрыть).
_shield_clean() { printf '%s' "$1" | tr -d '\000-\010\013-\037\177\\' | tr '\n\t' '  ' | cut -c1-160; }

shield_log() {
    _shield_paths
    [ -d "$SHIELD_DIR" ] || return 0
    printf '[%(%F %T)T] %s\n' -1 "$*" >> "$SHIELD_LOG" 2>/dev/null
    chmod 600 "$SHIELD_LOG" 2>/dev/null
    local s
    s=$(wc -c < "$SHIELD_LOG" 2>/dev/null) || s=0; s="${s//[^0-9]/}"
    if [ "${s:-0}" -gt 262144 ]; then
        tail -n 2000 "$SHIELD_LOG" > "$SHIELD_LOG.tmp" 2>/dev/null && chmod 600 "$SHIELD_LOG.tmp" 2>/dev/null && mv -f "$SHIELD_LOG.tmp" "$SHIELD_LOG"
    fi
    return 0
}

# Один за раз: таймер, меню и команда. Вложенные вызовы не ждут сами себя.
# Замок для действий человека: занят — сразу сказать, что ждём, и ждать.
# Кто держит, не знаем (такт с сетью при закрытом GitHub — минуты, или другой
# сеанс меню), поэтому без догадок; 3 минуты покрывают такт с 4 попытками.
_shield_lock_say() {  # _shield_lock_say [секунд ожидания]
    local w="${1:-180}"
    _shield_lock 0 && return 0
    say "$(bi "Защиту сейчас занимает другая операция — жду её завершения (до $(( (w + 59) / 60 )) мин)…" "Another operation is using the protection — waiting for it to finish (up to $(( (w + 59) / 60 )) min)…")"
    _shield_lock "$w" && return 0
    err "$(bi "Защита всё ещё занята другой операцией — попробуйте позже." "The protection is still busy with another operation — try again later.")"
    return 1
}
_shield_lock() {  # _shield_lock [секунд ожидания]
    if [ "${SHIELD_LOCKN:-0}" -gt 0 ]; then SHIELD_LOCKN=$(( SHIELD_LOCKN + 1 )); return 0; fi
    _shield_paths
    if command -v flock >/dev/null 2>&1 && mkdir -p "$SHIELD_DIR" 2>/dev/null; then
        chmod 700 "$SHIELD_DIR" 2>/dev/null
        if exec {SHIELD_LOCKFD}>>"$SHIELD_DIR/.lock"; then
            chmod 600 "$SHIELD_DIR/.lock" 2>/dev/null
            if ! flock -w "${1:-60}" "$SHIELD_LOCKFD"; then exec {SHIELD_LOCKFD}>&-; SHIELD_LOCKFD=""; return 1; fi
        else SHIELD_LOCKFD=""; fi
    fi
    SHIELD_LOCKN=1
    return 0
}
_shield_unlock() {
    [ "${SHIELD_LOCKN:-0}" -gt 0 ] || return 0
    SHIELD_LOCKN=$(( SHIELD_LOCKN - 1 ))
    [ "$SHIELD_LOCKN" -eq 0 ] || return 0
    if [ -n "${SHIELD_LOCKFD:-}" ]; then flock -u "$SHIELD_LOCKFD" 2>/dev/null; exec {SHIELD_LOCKFD}>&-; SHIELD_LOCKFD=""; fi
    return 0
}

shield_installed() { _shield_paths; [ -f "$SHIELD_DIR/settings" ]; }

# Адреса самого сервера и его DNS: сети с ними из списка выкидываются,
# сами адреса — в исключения.
shield_addrs() {
    if [ -n "${GOINST_TEST:-}" ]; then printf '%s\n' ${GOINST_SHIELD_ADDRS:-}; return 0; fi
    ip -o addr show 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "inet" || $i == "inet6") { a = $(i + 1); sub(/\/.*/, "", a); print a } }'
    sed -n -E 's/^[[:space:]]*nameserver[[:space:]]+([0-9A-Fa-f:.]+).*/\1/p' /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null
    return 0
}
# Порты ssh.socket (сокет-активация, Ubuntu 22.10+): порт переносят
# override-файлом с ListenStream, а sshd_config не трогают — и слушает его
# systemd, которого osup_ssh_ports берёт только на портах из настроек.
# Спросить systemd; и файлы — на случай, когда он не ответил.
shield_ssh_sock_ports() {
    local r="${GOINST_FS_ROOT:-}" f
    if command -v systemctl >/dev/null 2>&1; then
        systemctl show -p Listen ssh.socket 2>/dev/null | sed -n -E 's/^Listen=(.*:)?([0-9]+) \(Stream\)$/\2/p'
    fi
    for f in "$r/etc/systemd/system/ssh.socket" "$r"/etc/systemd/system/ssh.socket.d/*.conf "$r"/run/systemd/generator/ssh.socket.d/*.conf; do
        [ -f "$f" ] || continue
        sed -n -E 's/^[[:space:]]*ListenStream[[:space:]]*=[[:space:]]*(.*:)?([0-9]+)[[:space:]]*$/\2/p' "$f" 2>/dev/null
    done
    return 0
}
# Порты SSH: слушающий демон, настройки sshd (как в 1.1.0) и ssh.socket —
# объединение. Не узнали ничего — 22: без входа человек не останется ни при
# каком исходе. Лишний порт в списке безвреден (его только не блокируем).
shield_ssh_ports() {
    local p out=" "
    for p in $(osup_ssh_ports --daemon 2>/dev/null) $(osup_ssh_cfg_ports 2>/dev/null) $(shield_ssh_sock_ports); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
        case "$out" in *" $p "*) ;; *) out+="$p " ;; esac
    done
    [ "$out" = " " ] && out=" 22 "
    out="${out# }"; printf '%s' "${out% }"
}
# _shield_fp <порты> <файл адресов> <службы-прокси> — отпечаток: порты, версия
# текста правил, адреса сервера, влияющие на правила (_shield_py own: без
# частных и fe80, по числу), и службы-прокси с номерами их cgroup. Без
# python — все адреса, но в C-локали: порядок sort -u иначе зависит от языка
# (К3-11), и отпечаток прыгал бы между запуском из меню и таймером.
_shield_fp() {
    local a
    a=$(_shield_py own "$2" 2>/dev/null) || a=$(LC_ALL=C sort -u "$2" 2>/dev/null)
    printf '%s|%s|r%s|%s' "$1" "$(printf '%s\n' "$a" | cksum)" "$SHIELD_RULES_REV" "$(printf '%s' "${3:-}" | cksum)"
}
# Службы-прокси, что работают сейчас: «system.slice/<юнит>.service:<номер>»
# через пробел. nft узнаёт службу по номеру каталога cgroup v2, взятому при
# загрузке правил; перезапуск службы даёт новый каталог с новым номером —
# отпечаток меняется, и ближайший такт пересобирает правила. Без cgroup v2
# в /sys/fs/cgroup (Ubuntu 20.04: смешанная иерархия) и с выключенным ВК
# (выход не считается) — пусто.
_shield_cgroot() {
    if [ -n "${GOINST_TEST:-}" ] && [ -n "${GOINST_SHIELD_CG:-}" ]; then printf '%s' "$GOINST_SHIELD_CG"; else printf '/sys/fs/cgroup'; fi
}
_shield_prx() {
    local r u d i out=""
    [ "$(_shield_get "$SHIELD_DIR/settings" vk 2>/dev/null)" = 1 ] || return 0
    r=$(_shield_cgroot)
    [ -f "$r/cgroup.controllers" ] || return 0
    for u in $SHIELD_PROXY_UNITS; do
        d="$r/system.slice/$u.service"
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        read -r i _ < <(ls -di "$d" 2>/dev/null) || continue
        case "$i" in ''|*[!0-9]*) continue ;; esac
        out+="system.slice/$u.service:$i "
    done
    printf '%s' "${out% }"
}

# shield_fetch <каталог> [прежний хеш] — скачать пять файлов списка. Без
# ключа клуба: свой конфиг curl, -q первым (чужой ~/.curlrc не подмешается),
# только https. Хеш коммита — у API, файлы — по нему; хеша нет — по ветке.
# rc 0 — скачано (SHIELD_SHA), 2 — хеш тот же, качать нечего, 1 — не вышло
# (SHIELD_ERR словами).
shield_fetch() {
    local d="$1" prev="${2:-}" cfg sha="" ref f code rc
    local GH_SAY="${SHIELD_SAY:-}" GH_DOWN_FILE="" GH_WHAT=""
    SHIELD_SHA=""; SHIELD_ERR=""
    cfg="$d/.curl"
    : > "$cfg" && chmod 600 "$cfg" || { SHIELD_ERR=$(bi "нет места для временных файлов" "no room for temporary files"); return 1; }
    {
        echo 'silent'; echo 'location'
        gh_cfg_net
        echo 'max-time = 60'; echo 'max-filesize = 8000000'
        echo 'proto = "=https"'; echo 'proto-redir = "=https"'
    } > "$cfg"
    GH_DOWN_FILE="$d/.down"; : > "$GH_DOWN_FILE"
    if [ -z "${GOINST_NO_SHA:-}" ]; then
        GH_WHAT="AS_Network_List"
        code=$(gh_curl -q --config "$cfg" -H 'Accept: application/vnd.github.sha' -o "$d/.sha" -w '%{http_code}' \
               "https://api.github.com/repos/${SHIELD_REPO}/commits/${SHIELD_REF}")
        [ "$code" = 200 ] && { IFS= read -r sha < "$d/.sha" || true; } 2>/dev/null
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || sha=""
        rm -f "$d/.sha"
    fi
    if [ -n "$sha" ] && [ "$sha" = "$prev" ]; then SHIELD_SHA="$sha"; rm -f "$cfg" "$GH_DOWN_FILE"; return 2; fi
    ref="${sha:-$SHIELD_REF}"
    for f in "${SHIELD_FILES[@]}"; do
        GH_WHAT="$f"
        code=$(gh_curl -q --config "$cfg" -o "$d/$f" -w '%{http_code}' \
               "https://raw.githubusercontent.com/${SHIELD_REPO}/${ref}/${SHIELD_PATH}/${f}"); rc=$?
        if [ "$rc" -ne 0 ] || [ "$code" != 200 ]; then
            if _gh_net_rc "$rc"; then SHIELD_ERR="$(bi "GitHub не ответил" "GitHub did not answer"): $(gh_net_reason "$rc")"
            elif [ "$rc" = 63 ]; then SHIELD_ERR=$(bi "${f} больше 8 МБ" "${f} is larger than 8 MB")
            else SHIELD_ERR=$(bi "GitHub ответил ${code:-?} на ${f}" "GitHub answered ${code:-?} for ${f}"); fi
            rm -f "$cfg" "$GH_DOWN_FILE"; return 1
        fi
    done
    rm -f "$cfg" "$GH_DOWN_FILE"
    SHIELD_SHA="$sha"
    return 0
}

# Причина отказа разбора — словами.
_shield_rej_text() {  # _shield_rej_text <файл> <код> <вывод разбора>
    local f="$1" rc="$2" out="$3" a b
    read -r _ a b <<<"$out"
    case "$rc" in
        2) bi "${f}: строка ${a:-?} — не сеть (${b:-?})" "${f}: line ${a:-?} is not a network (${b:-?})" ;;
        3) bi "${f}: слишком широкая сеть ${a:-?} — похоже на порчу источника" "${f}: too wide a network ${a:-?} — looks like a corrupted source" ;;
        4) bi "${f}: слишком большой файл" "${f}: the file is too large" ;;
        127) bi "нет python3 — разобрать список нечем" "python3 is missing — nothing to parse the list with" ;;
        *) bi "${f}: не прочитан (код ${rc})" "${f}: could not be read (code ${rc})" ;;
    esac
}
# Адреса GitHub, откуда качают goInstaller, продукты и сама защита. Цепочка
# vk_output режет и исходящие сервера: сеть ВК с таким адресом отрезала бы
# сервер от обновлений (К2-6C). Строка — адрес; «-имя» — имя не разрешилось.
# Имена — разом, не друг за другом: без DNS это 10 с, а не 40, и такт под
# замком не держит действия человека лишнее.
_shield_gh_addrs() {
    local h a
    if [ -n "${GOINST_TEST:-}" ]; then printf '%s\n' ${GOINST_SHIELD_GH_ADDRS:-}; return 0; fi
    if ! command -v getent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then printf -- '-%s\n' getent; return 0; fi
    for h in api.github.com raw.githubusercontent.com github.com codeload.github.com; do
        {
            a=$(timeout 10 getent ahosts "$h" 2>/dev/null | awk '!s[$1]++ { print $1 }')
            if [ -n "$a" ]; then printf '%s\n' "$a"; else printf -- '-%s\n' "$h"; fi
        } &
    done
    wait
}
# → SHIELD_GH (адреса), SHIELD_GHMISS (какие имена не разрешились, через запятую).
_shield_gh_resolve() {
    local l
    SHIELD_GH=(); SHIELD_GHMISS=""
    while IFS= read -r l; do
        case "$l" in
            -*) SHIELD_GHMISS+="${SHIELD_GHMISS:+, }${l#-}" ;;
            *[!0-9A-Fa-f:.]*|'') ;;
            *) SHIELD_GH+=("$l") ;;
        esac
    done < <(_shield_gh_addrs)
}
# Сверка ВК с GitHub не вышла полностью — сказать в журнал, а не молчать
# (REVIEW-3 №2а). rc 1 — сверять не с чем.
_shield_gh_note() {
    if [ "${#SHIELD_GH[@]}" -eq 0 ]; then
        shield_log "$(bi "сверка ВК с адресами GitHub пропущена: адреса GitHub не разрешились" "the VK check against the GitHub addresses is skipped: the GitHub addresses did not resolve")${SHIELD_GHMISS:+ (${SHIELD_GHMISS})}"
        return 1
    fi
    [ -z "$SHIELD_GHMISS" ] || shield_log "$(bi "сверка ВК с адресами GitHub неполная: не разрешились" "the VK check against the GitHub addresses is partial: did not resolve") ${SHIELD_GHMISS}"
    return 0
}
# Сети ВК против адресов SHIELD_GH; свои исключения пропускают адрес и в
# цепочках ВК — такой адрес не помеха. rc 0 — чисто, 7 — нашлось
# (SHIELD_GHNET, SHIELD_GHADDR), иное — не сверить.
_shield_vk_gh() {  # _shield_vk_gh <vk4> <vk6>
    local out rc
    SHIELD_GHNET=""; SHIELD_GHADDR=""
    out=$(_shield_py hits "$1" "$2" "$SHIELD_DIR/exclude" "${SHIELD_GH[@]}" 2>/dev/null); rc=$?
    [ "$rc" = 7 ] && read -r _ SHIELD_GHNET SHIELD_GHADDR <<<"$out"
    return "$rc"
}
# Список ВК пуст (оба файла пусты или их нет) — закрывать нечего.
_shield_vk_empty() {  # _shield_vk_empty [каталог списков]
    local l="${1:-$SHIELD_DIR/lists}"
    [ ! -s "$l/vk4" ] && [ ! -s "$l/vk6" ]
}
# shield_accept <каталог скачанного> — проверить и принять. rc 0 — принят
# (SHIELD_VKERR непуст — список ВК не прошёл, работает прежний ВК; прежнего
# нет — SHIELD_VKNONE=1, ВК пуст), 1 — отказ
# общего списка (SHIELD_ERR): работает прежний принятый целиком.
# Общий и ВК проверяются раздельно: ошибка источника в ВК (сеть вне общего,
# рост, GitHub) не должна замораживать защиту от сканеров у всех.
shield_accept() {
    local d="$1" new="$SHIELD_DIR/lists.new" om="$SHIELD_DIR/lists/meta" out rc s f fam dst n4 prev tvk k a pa lim nm u fl base e
    local -A cnt=() cov=()
    SHIELD_ERR=""; SHIELD_VKERR=""; SHIELD_VKNONE=""
    rm -rf "$new"; mkdir -p "$new" && chmod 700 "$new" || { SHIELD_ERR=$(bi "не создать ${new}" "cannot create ${new}"); return 1; }
    for s in "blacklist-v4.txt 4 scan4" "blacklist-v6.txt 6 scan6" "blacklist-vk-v4.txt 4 vk4" "blacklist-vk-v6.txt 6 vk6"; do
        read -r f fam dst <<<"$s"
        case "$dst" in vk*) [ -z "$SHIELD_VKERR" ] || continue ;; esac
        e=""
        out=$(_shield_py list "$d/$f" "$fam" "$new/$dst" 2>/dev/null); rc=$?
        if [ "$rc" -ne 0 ]; then e=$(_shield_rej_text "$f" "$rc" "$out")
        else
            read -r k a <<<"$out"
            case "$k" in ''|*[!0-9]*) k=x ;; esac; case "$a" in ''|*[!0-9]*) k=x ;; esac
            [ "$k" = x ] && e=$(_shield_rej_text "$f" 1 "")
        fi
        if [ -n "$e" ]; then
            case "$dst" in vk*) SHIELD_VKERR="$e"; continue ;; esac
            SHIELD_ERR="$e"; rm -rf "$new"; return 1
        fi
        cnt[$dst]="$k"; cov[$dst]="$a"
    done
    n4="${cnt[scan4]:-0}"
    prev=$(_shield_num "$om" n4)
    if [ "$n4" -lt "$SHIELD_MIN4" ]; then
        SHIELD_ERR=$(bi "в общем списке v4 всего ${n4} сетей, нужно не меньше ${SHIELD_MIN4}" "the general v4 list has only ${n4} networks, at least ${SHIELD_MIN4} are required")
    elif [ "$prev" -gt 0 ] && [ $(( n4 * 2 )) -lt "$prev" ]; then
        SHIELD_ERR=$(bi "общий список v4 сжался больше чем вдвое: ${n4} против ${prev}" "the general v4 list shrank more than twofold: ${n4} against ${prev}")
    elif [ "$prev" -gt 0 ] && [ "$n4" -gt $(( prev * 3 )) ]; then
        SHIELD_ERR=$(bi "общий список v4 вырос больше чем втрое: ${n4} против ${prev}" "the general v4 list grew more than threefold: ${n4} against ${prev}")
    fi
    # Охват каждого из четырёх: потолок и рост против прошлого принятого, не
    # меньше пола (поля u4 u6 uvk4 uvk6 в meta; прежней версии их нет — рост
    # не судим). Сбой общего — отказ всему, сбой ВК — только ВК.
    if [ -z "$SHIELD_ERR" ]; then
        for k in scan4 scan6 vk4 vk6; do
            case "$k" in
                scan4) nm=$(bi "общий v4" "general v4"); lim="$SHIELD_MAX4"; fl="$SHIELD_FLOOR4"; u=/24; f=u4 ;;
                scan6) nm=$(bi "общий v6" "general v6"); lim="$SHIELD_MAX6"; fl="$SHIELD_FLOOR6"; u=/48; f=u6 ;;
                vk4)   nm=$(bi "ВК v4" "VK v4"); lim="$SHIELD_MAX4"; fl="$SHIELD_FLOOR4"; u=/24; f=uvk4 ;;
                vk6)   nm=$(bi "ВК v6" "VK v6"); lim="$SHIELD_MAX6"; fl="$SHIELD_FLOOR6"; u=/48; f=uvk6 ;;
            esac
            case "$k" in vk*) [ -z "$SHIELD_VKERR" ] || break ;; esac
            a="${cov[$k]:-0}"; pa=""; e=""
            _shield_get "$om" "$f" >/dev/null && pa=$(_shield_num "$om" "$f")
            base="$pa"; [ -n "$base" ] && [ "$base" -lt "$fl" ] && base="$fl"
            if [ "$a" -gt "$lim" ]; then
                e=$(bi "список ${nm} накрывает ${a} сетей ${u}, больше потолка ${lim} — похоже на порчу источника" "the ${nm} list covers ${a} ${u} networks, over the ceiling of ${lim} — looks like a corrupted source")
            elif [ -n "$base" ] && [ "$a" -gt $(( base * 3 )) ]; then
                e=$(bi "охват списка ${nm} вырос больше чем втрое: ${a} против ${pa} сетей ${u}" "the ${nm} list coverage grew more than threefold: ${a} against ${pa} ${u} networks")
            fi
            [ -n "$e" ] || continue
            case "$k" in vk*) SHIELD_VKERR="$e" ;; *) SHIELD_ERR="$e"; break ;; esac
        done
    fi
    if [ -n "$SHIELD_ERR" ]; then rm -rf "$new"; return 1; fi
    # ВК v4 — часть общего (так у проекта: ВК среди госорганов). v6 так не
    # проверить: у проекта ВК v6 шире.
    if [ -z "$SHIELD_VKERR" ] && [ -s "$new/vk4" ]; then
        out=$(_shield_py within "$new/vk4" "$new/scan4" 2>/dev/null); rc=$?
        case "$rc" in
            0) ;;
            7) SHIELD_VKERR=$(bi "в списке ВК v4 сеть ${out#out } вне общего списка — похоже на порчу источника" "the VK v4 list has ${out#out } outside the general list — looks like a corrupted source") ;;
            *) SHIELD_VKERR=$(bi "список ВК v4 не сверить с общим (код ${rc})" "cannot match the VK v4 list against the general one (code ${rc})") ;;
        esac
    fi
    # Сеть ВК с адресом GitHub отрезала бы сервер от обновлений (vk_output).
    # Не разрешились адреса — строка в журнал (REVIEW-3 №2а).
    if [ -z "$SHIELD_VKERR" ] && ! _shield_vk_empty "$new"; then
        _shield_gh_resolve
        if _shield_gh_note; then
            _shield_vk_gh "$new/vk4" "$new/vk6"; rc=$?
            case "$rc" in
                0) ;;
                7) SHIELD_VKERR=$(bi "в списке ВК сеть ${SHIELD_GHNET:-?} с адресом GitHub ${SHIELD_GHADDR:-?} — она отрезала бы сервер от обновлений" "the VK list has ${SHIELD_GHNET:-?} holding the GitHub address ${SHIELD_GHADDR:-?} — it would cut the server off from updates") ;;
                *) SHIELD_VKERR=$(bi "список ВК не сверить с адресами GitHub (код ${rc})" "cannot match the VK list against the GitHub addresses (code ${rc})") ;;
            esac
        fi
    fi
    # ВК не прошёл — прежний ВК (его нет — пустой), общий принимаем.
    if [ -n "$SHIELD_VKERR" ]; then
        SHIELD_VKNONE=""; _shield_vk_empty && SHIELD_VKNONE=1
        for k in vk4 vk6; do
            if [ -f "$SHIELD_DIR/lists/$k" ]; then cp -f "$SHIELD_DIR/lists/$k" "$new/$k"; else : > "$new/$k"; fi
        done
        cnt[vk4]=$(_shield_num "$om" vk4); cnt[vk6]=$(_shield_num "$om" vk6)
        cov[vk4]=$(_shield_num "$om" uvk4); cov[vk6]=$(_shield_num "$om" uvk6)
        if [ -n "$SHIELD_VKNONE" ]; then
            shield_log "$(bi "список ВК отклонён: ${SHIELD_VKERR}; прежнего нет — ВК пуст" "the VK list is rejected: ${SHIELD_VKERR}; there is no previous one — VK is empty")"
        else
            shield_log "$(bi "список ВК отклонён: ${SHIELD_VKERR}; работает прежний ВК" "the VK list is rejected: ${SHIELD_VKERR}; the previous VK keeps working")"
        fi
    fi
    # Исключения по умолчанию (TVK-AS) — из файла с именами AS. Не разобрался
    # он — не беда: это только исключения, список от него не зависит.
    tvk=$(_shield_py tvk "$d/blacklist_with_comments.txt" "$SHIELD_TVK" "$new/scan4" "$new/scan6" "$new/tvk4" "$new/tvk6" 2>/dev/null) || tvk=""
    case "$tvk" in ''|*[!0-9]*) tvk=0; : > "$new/tvk4"; : > "$new/tvk6" ;; esac
    # Подписи сетей для статистики (чья сеть) — из того же файла; не
    # разобрался — без подписей, на список не влияет.
    _shield_spy owners "$d/blacklist_with_comments.txt" "$new/owners" >/dev/null 2>&1 || : > "$new/owners"
    printf 'sha=%s\ndate=%s\nn4=%s\nn6=%s\nvk4=%s\nvk6=%s\ntvk=%s\nu4=%s\nu6=%s\nuvk4=%s\nuvk6=%s\n' "${SHIELD_SHA:-}" "$(_shield_now)" \
        "$n4" "${cnt[scan6]:-0}" "${cnt[vk4]:-0}" "${cnt[vk6]:-0}" "$tvk" "${cov[scan4]:-0}" "${cov[scan6]:-0}" "${cov[vk4]:-0}" "${cov[vk6]:-0}" > "$new/meta"
    chmod 600 "$new"/* 2>/dev/null
    rm -rf "$SHIELD_DIR/lists.old"
    [ -d "$SHIELD_DIR/lists" ] && mv -f "$SHIELD_DIR/lists" "$SHIELD_DIR/lists.old"
    mv -f "$new" "$SHIELD_DIR/lists" || { [ -d "$SHIELD_DIR/lists.old" ] && mv -f "$SHIELD_DIR/lists.old" "$SHIELD_DIR/lists"; SHIELD_ERR="mv"; return 1; }
    rm -rf "$SHIELD_DIR/lists.old"
    e=""
    if [ -n "$SHIELD_VKNONE" ]; then e=$(bi " (пуст: прежнего нет)" " (empty: no previous one)")
    elif [ -n "$SHIELD_VKERR" ]; then e=$(bi " (прежний)" " (previous)"); fi
    shield_log "$(bi "список принят: v4 ${n4}, v6 ${cnt[scan6]:-0}, ВК ${cnt[vk4]:-0}+${cnt[vk6]:-0}${e}, ${SHIELD_TVK} ${tvk}, хеш ${SHIELD_SHA:-ветка ${SHIELD_REF}}" "list accepted: v4 ${n4}, v6 ${cnt[scan6]:-0}, VK ${cnt[vk4]:-0}+${cnt[vk6]:-0}${e}, ${SHIELD_TVK} ${tvk}, hash ${SHIELD_SHA:-branch ${SHIELD_REF}}")"
    return 0
}

# nft: сначала проверка (-c), не прошла — не применяем.
_shield_nft_load() {  # _shield_nft_load <файл> [checked — проверку уже прошёл]
    local out
    if [ "${2:-}" != checked ] && ! out=$(_shield_nft -c -f "$1" 2>&1); then
        SHIELD_ERR="$(bi "nft не принял правила" "nft rejected the rules"): $(_shield_clean "${out:-?}")"; return 1
    fi
    if ! out=$(_shield_nft -f "$1" 2>&1); then
        SHIELD_ERR="$(bi "nft не загрузил правила" "nft did not load the rules"): $(_shield_clean "${out:-?}")"; return 1
    fi
    return 0
}
# shield_apply — собрать shield.nft из принятого списка и настроек и
# загрузить одной транзакцией. rc 0; 1 — SHIELD_ERR.
# Статистика (1.2.4): уровень 3 → 0 — первый, что принял nft -c (он идёт в
# ядро); не умеют nft или ядро — правило счёта не ставится, в статистике
# «нет данных», остальное как было. Принятое не загрузилось — ещё раз уровнем
# 0. Уровень 0 не принят — ошибка, как до 1.2.4. Перед пересборкой — снимок:
# счётчики таблицы обнулятся.
shield_apply() {
    local scan vk ports out rc new="$SHIELD_DIR/shield.nft.new" n x l lv ck okc="" stl0 prx pp="" up pn=""
    local -a tries
    SHIELD_ERR=""
    scan=$(_shield_get "$SHIELD_DIR/settings" scan) || scan=0; [ "$scan" = 1 ] || scan=0
    vk=$(_shield_get "$SHIELD_DIR/settings" vk) || vk=0; [ "$vk" = 1 ] || vk=0
    ports=$(shield_ssh_ports)
    shield_addrs > "$SHIELD_DIR/addrs" 2>/dev/null; chmod 600 "$SHIELD_DIR/addrs" 2>/dev/null
    [ -f "$SHIELD_DIR/dropped" ] && mv -f "$SHIELD_DIR/dropped" "$SHIELD_DIR/dropped.prev"
    shield_stats_snap
    prx=$(_shield_prx)
    for x in $prx; do pp+="${x%:*} "; done
    pp="${pp% }"
    # Каждый уровень — со службами-прокси, не принял nft (старые nft или ядро,
    # служба перезапустилась) — тот же уровень без них: выход прокси тогда
    # считается сервером, подпись в отчёте об этом говорит.
    for lv in 3 2 1 0; do
        tries=("")
        [ -n "$pp" ] && [ "$vk" = 1 ] && [ "$lv" != 0 ] && tries=("$pp" "")
        for up in "${tries[@]}"; do
            out=$(_shield_py render "$SHIELD_DIR" "$scan" "$vk" "$ports" "$SHIELD_DIR/addrs" "$new" "$lv" "$up" 2>/dev/null); rc=$?
            if [ "$rc" -ne 0 ]; then
                if [ "$rc" = 127 ]; then SHIELD_ERR=$(bi "нет python3" "python3 is missing"); else SHIELD_ERR=$(bi "правила не собрались (код ${rc})" "the rules were not built (code ${rc})"); fi
                rm -f "$new"; return 1
            fi
            chmod 600 "$new" 2>/dev/null
            if ck=$(_shield_nft -c -f "$new" 2>&1); then okc=1; break 2; fi
        done
    done
    if [ -z "$okc" ]; then
        SHIELD_ERR="$(bi "nft не принял правила" "nft rejected the rules"): $(_shield_clean "${ck:-?}")"
        rm -f "$new"; return 1
    fi
    if ! _shield_nft_load "$new" checked; then
        # nft -c принял, а загрузка не прошла: со службами-прокси — тот же
        # уровень без них (служба остановилась между проверкой и загрузкой);
        # иначе (скажем, ядру не хватило памяти на наборы счёта) статистика не
        # стоит защиты — ещё раз без неё.
        if [ -n "$up" ] && out=$(_shield_py render "$SHIELD_DIR" "$scan" "$vk" "$ports" "$SHIELD_DIR/addrs" "$new" "$lv" "" 2>/dev/null) \
            && chmod 600 "$new" && _shield_nft_load "$new"; then
            up=""; SHIELD_ERR=""
        else
            [ "$lv" != 0 ] && out=$(_shield_py render "$SHIELD_DIR" "$scan" "$vk" "$ports" "$SHIELD_DIR/addrs" "$new" 0 2>/dev/null) \
                && chmod 600 "$new" && _shield_nft_load "$new" || { rm -f "$new"; return 1; }
            lv=0; up=""; SHIELD_ERR=""
        fi
    fi
    # Какие службы-прокси считаются клиентами (для отчёта): имена через запятую.
    for x in $up; do x="${x#system.slice/}"; pn+="${x%.service},"; done
    mv -f "$new" "$SHIELD_DIR/shield.nft"
    n="${out#*nets=}"; n="${n%% *}"; x="${out#*nx=}"; x="${x%% *}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac; case "$x" in ''|*[!0-9]*) x=0 ;; esac
    stl0=$(_shield_get "$SHIELD_DIR/status" stl) || stl0=""
    _shield_set "$SHIELD_DIR/status" "nets=$n" "nx=$x" "ports=$ports" "fp=$(_shield_fp "$ports" "$SHIELD_DIR/addrs" "$prx")" "applied=$(_shield_now)" "stl=$lv" "prx=${pn%,}"
    if [ "$stl0" != "$lv" ]; then
        case "$lv" in
            3) shield_log "$(bi "статистика: полная" "statistics: full")" ;;
            0) shield_log "$(bi "статистика: nft или ядро не умеют счётчиков — не ведётся, защита работает" "statistics: nft or the kernel cannot count — not kept, the protection works")" ;;
            *) shield_log "$(bi "статистика: неполная (уровень ${lv} из 3) — nft или ядро умеют не всё" "statistics: partial (level ${lv} of 3) — nft or the kernel cannot do everything")" ;;
        esac
    fi
    # Выкинутые из списка сети — в журнал, когда их набор сменился.
    if [ -s "$SHIELD_DIR/dropped" ] && ! cmp -s "$SHIELD_DIR/dropped" "$SHIELD_DIR/dropped.prev" 2>/dev/null; then
        while IFS= read -r l; do
            shield_log "$(bi "из списка выкинута сеть (частная, служебная или с адресом сервера)" "dropped from the list (private, special or holds a server address)"): $l"
        done < <(head -n 20 "$SHIELD_DIR/dropped")
    fi
    rm -f "$SHIELD_DIR/dropped.prev"
    return 0
}

# shield_live_ok — правила на месте: таблица есть, включённые цепочки и
# наборы не пусты; статистика ставилась (stl ≥ 1) — и правила счёта.
# → SHS_DROPS, SHS_REJS; rc 1 — SHIELD_LIVE (что не так).
# Таблица — без элементов наборов (nft -t): в наборах счёта до ~139 тыс.
# записей, полный листинг — секунды на каждое открытие меню (REVIEW-6 №5).
# Непустоту нужных наборов проверяет листинг каждого по имени.
shield_live_ok() {
    local scan vk out r want stl x o el=""
    SHS_DROPS=""; SHS_REJS=""; SHIELD_LIVE=""
    scan=$(_shield_get "$SHIELD_DIR/settings" scan) || scan=0
    vk=$(_shield_get "$SHIELD_DIR/settings" vk) || vk=0
    stl=$(_shield_num "$SHIELD_DIR/status" stl)
    [ "$scan" = 1 ] || [ "$vk" = 1 ] || [ "$stl" -ge 1 ] || return 0
    if ! out=$(_shield_nft -t list table inet "$SHIELD_TABLE" 2>/dev/null); then SHIELD_LIVE=table; return 1; fi
    # Непустыми должны быть те наборы, что непусты в загруженном shield.nft:
    # пустой список ВК (или всё в исключениях) — не поломка. Файла нет —
    # прежнее требование: scan4 и vk4.
    want=$(awk '/^[ \t]*set [A-Za-z0-9_]+ \{/ { cur = $2; next }
        /elements = / && cur != "" { printf "%s ", cur; cur = "" }' "$SHIELD_DIR/shield.nft" 2>/dev/null) || want=""
    for x in ${want:-scan4 vk4}; do
        o=$(_shield_nft list set inet "$SHIELD_TABLE" "$x" 2>/dev/null) || continue
        [[ "$o" == *"elements = "* ]] && el+="$x "
    done
    r=$(awk -v scan="$scan" -v vk="$vk" -v stl="$stl" -v want="$want" -v els="$el" '
        BEGIN { n = split(els, e, " "); for (i = 1; i <= n; i++) el[e[i]] = 1 }
        /^[ \t]*chain [A-Za-z0-9_]+ \{/ { ch[$2] = 1; next }
        /@scan4/ && / drop/ { sd = 1 }
        / drop/ && /counter packets/ { for (i = 1; i < NF; i++) if ($i == "packets") dr += $(i + 1) }
        / reject/ && /counter packets/ { for (i = 1; i < NF; i++) if ($i == "packets") rj += $(i + 1) }
        END {
            n = split(want, w, " ")
            if (n == 0) { w[1] = "scan4"; w[2] = "vk4"; n = 2 }
            for (i = 1; i <= n; i++) if (!el[w[i]]) {
                if (w[i] ~ /^vk/) mv = 1; else if (w[i] ~ /^scan/) ms = 1; else { ms = 1; mv = 1 }
            }
            bad = ""
            if (scan == 1 && (!ch["incoming"] || ms || !sd)) bad = "scan"
            if (vk == 1 && (!ch["vk_forward"] || !ch["vk_output"] || mv)) bad = bad (bad != "" ? "," : "") "vk"
            if (stl >= 1 && bad == "" && (!ch["incoming"] || !ch["stat4"] || !ch["stat6"] || ms)) bad = "count"
            printf "%s %d %d\n", (bad == "" ? "ok" : bad), dr, rj
        }' <<<"$out")
    read -r SHIELD_LIVE SHS_DROPS SHS_REJS <<<"$r"
    [ "$SHIELD_LIVE" = ok ] && { SHIELD_LIVE=""; return 0; }
    return 1
}
_shield_live_text() {
    case "$1" in
        table) bi "таблицы ${SHIELD_TABLE} нет" "the ${SHIELD_TABLE} table is missing" ;;
        scan)  bi "правила сканеров пусты или неполны" "the scanner rules are empty or incomplete" ;;
        vk)    bi "правила ВК пусты или неполны" "the VK rules are empty or incomplete" ;;
        count) bi "правила счёта статистики пропали" "the statistics counting rules are gone" ;;
        *)     bi "правила неполны" "the rules are incomplete" ;;
    esac
}

# Порты SSH и адреса сервера сверить с применёнными (отпечаток fp в
# status); разошлись — пересобрать. «SSH не блокируется никогда»: новый порт
# должен попасть в правила при первой же проверке, а не через час. rc 1 —
# пересобрать не вышло (SHIELD_ERR).
# Отпечаток портов SSH и адресов сервера сейчас.
_shield_fp_now() {
    shield_addrs > "$SHIELD_DIR/addrs.now" 2>/dev/null
    _shield_fp "$(shield_ssh_ports)" "$SHIELD_DIR/addrs.now" "$(_shield_prx)"
    rm -f "$SHIELD_DIR/addrs.now"
}
_shield_fp_sync() {
    local fp
    # И при выключенной защите: правила счёта стоят и тогда (1.2.4), новая
    # версия правил (SHIELD_RULES_REV) ставится первым же тактом.
    shield_installed || return 0
    fp=$(_shield_fp_now)
    [ "$fp" = "$(_shield_get "$SHIELD_DIR/status" fp)" ] && return 0
    if shield_apply; then
        shield_log "$(bi "порты SSH, адреса сервера или службы-прокси сменились — правила пересобраны" "the SSH ports, server addresses or proxy services changed — the rules are rebuilt")"
        return 0
    fi
    shield_log "$(bi "порты SSH, адреса сервера или службы-прокси сменились, а правила не пересобрались: ${SHIELD_ERR}" "the SSH ports, server addresses or proxy services changed, but the rules did not rebuild: ${SHIELD_ERR}")"
    return 1
}
# Список старше 3 суток — защита работает по устаревшему: это сбой (status
# и меню говорят то же, shield_state).
_shield_stale() {
    local d
    _shield_enabled || return 1
    d=$(_shield_num "$SHIELD_DIR/lists/meta" date)
    [ "$d" -gt 0 ] && [ $(( $(_shield_now) - d )) -gt 259200 ]
}

# shield_check [--quiet] — проверить и при нужде восстановить. Код: 0 —
# работает (или выключено), 1 — не работает или список старше 3 суток,
# 3 — не стоит. Звать под _shield_lock.
shield_check() {
    local q="${1:-}" why
    shield_installed || return 3
    if ! _shield_fp_sync; then
        why=$(bi "порты SSH сменились, а правила не пересобрались: ${SHIELD_ERR}" "the SSH ports changed, but the rules did not rebuild: ${SHIELD_ERR}")
        _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=fail" "why=${why}" "wk=ports"
        [ -n "$q" ] || err "$(bi "Защита от сканеров не работает: ${why}" "Scanner protection is not working: ${why}")"
        return 1
    fi
    if shield_live_ok; then
        _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=ok" "why="
        _shield_check_rest "$q"; return $?
    fi
    why=$(_shield_live_text "$SHIELD_LIVE")
    if shield_apply && shield_live_ok; then
        shield_log "$(bi "правила пропали (${why}) — восстановлено" "the rules were gone (${why}) — restored")"
        _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=restored" "why=" "restored=$(_shield_now)"
        [ -n "$q" ] || warn "$(bi "Защита от сканеров: правила пропали (${why}) — восстановил." "Scanner protection: the rules were gone (${why}) — restored.")"
        _shield_check_rest "$q"; return $?
    fi
    why="${SHIELD_ERR:-$why}"
    shield_log "$(bi "не работает: ${why}" "not working: ${why}")"
    _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=fail" "why=${why}" "wk=rules"
    [ -n "$q" ] || err "$(bi "Защита от сканеров не работает: ${why}" "Scanner protection is not working: ${why}")"
    return 1
}

# Правила на месте; дальше — то, чего правила не чинят. Сеть ВК с адресом
# GitHub (нашёл такт, ghhit; REVIEW-3 №2б): сервер не дойдёт до обновлений,
# и через 3 суток было бы только «не скачался» — сбой со словами сразу.
# Потом — список старше 3 суток. rc 1.
_shield_check_rest() {  # _shield_check_rest [--quiet]
    local why
    why=$(_shield_gh_why)
    if [ -n "$why" ]; then
        _shield_set "$SHIELD_DIR/status" "result=fail" "why=${why}" "wk=gh"
        [ -n "${1:-}" ] || err "$(bi "Защита от сканеров: " "Scanner protection: ")${why}"
        return 1
    fi
    _shield_check_stale "${1:-}"
}
# ВК включён, а такт нашёл в нём адрес GitHub → причина словами (пусто — нет).
# Находку сверяет заново с нынешними списками и исключениями, без DNS:
# добавили адрес в исключения или пришёл список без этой сети — сбой снят
# сразу, а не через час, на следующем такте.
_shield_gh_why() {
    local h n a out
    [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ] || return 0
    h=$(_shield_get "$SHIELD_DIR/status" ghhit) || return 0
    read -r n a <<<"$h"
    [ -n "$a" ] || return 0
    case "$n$a" in *[!0-9A-Fa-f:./]*) return 0 ;; esac
    out=$(_shield_py hits "$SHIELD_DIR/lists/vk4" "$SHIELD_DIR/lists/vk6" "$SHIELD_DIR/exclude" "$a" 2>/dev/null)
    case "$?" in
        0) return 0 ;;
        7) read -r _ n _ <<<"$out" ;;
    esac
    bi "в списке ВК сеть ${n} с адресом GitHub ${a} — сервер не дойдёт до обновлений; выключите ВК (goinstall --shield vk off) или добавьте ${a} в исключения" \
       "the VK list has ${n} holding the GitHub address ${a} — the server cannot reach updates; turn VK off (goinstall --shield vk off) or add ${a} to the exclusions"
}
_shield_check_stale() {  # правила на месте; список старше 3 суток — rc 1
    _shield_stale || return 0
    [ -n "${1:-}" ] || err "$(bi "Защита от сканеров: " "Scanner protection: ")$(_shield_stale_why "$(_shield_num "$SHIELD_DIR/lists/meta" date)")"
    return 1
}
# Почему список устарел: с какого числа и чем кончилась последняя попытка
# (не скачался — upderr; скачался, но отклонён — rejwhy).
_shield_stale_why() {  # _shield_stale_why <дата списка, с>
    local st="$SHIELD_DIR/status" w r
    w=$(bi "список не обновлялся больше 3 суток (от $(printf '%(%d.%m)T' "$1"))" "the list has not updated for over 3 days (since $(printf '%(%d.%m)T' "$1"))")
    r=$(_shield_get "$st" upderr) || r=""
    if [ -n "$r" ]; then w+=" — $(bi "не скачался" "the download failed"): ${r}"
    else
        r=$(_shield_num "$st" rej)
        [ "$r" -gt 0 ] && [ "$r" -ge "$1" ] && w+=" — $(_shield_get "$st" rejwhy)"
    fi
    printf '%s' "$w"
}

# shield_update [--quiet] — скачать списки и, если сменились и прошли
# проверку, применить. rc 0 — обновлено или без изменений, 1 — нет.
shield_update() {
    local q="${1:-}" d prev rc
    shield_installed || return 3
    d=$(mktemp -d "${TMPDIR:-/tmp}/goinst-shield.XXXXXX") || return 1
    prev=$(_shield_get "$SHIELD_DIR/lists/meta" sha) || prev=""
    [ -s "$SHIELD_DIR/lists/scan4" ] || prev=""
    # Подписей сетей нет (список принят до 1.2.4) — скачать и при том же хеше.
    [ -e "$SHIELD_DIR/lists/owners" ] || prev=""
    [ -n "$q" ] || say "$(bi "Скачиваю списки AS_Network_List…" "Downloading the AS_Network_List lists…")"
    SHIELD_SAY=""; [ -n "$q" ] || SHIELD_SAY=1
    shield_fetch "$d" "$prev"; rc=$?
    if [ "$rc" -eq 2 ]; then
        rm -rf "$d"
        _shield_set "$SHIELD_DIR/lists/meta" "date=$(_shield_now)"
        _shield_set "$SHIELD_DIR/status" "upd=$(_shield_now)" "upderr=" "rej=" "rejwhy="
        shield_log "$(bi "список без изменений (хеш ${prev:0:7})" "the list is unchanged (hash ${prev:0:7})")"
        [ -n "$q" ] || ok "$(bi "Списки не менялись — на месте свежие." "The lists have not changed — the current ones are fresh.")"
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        rm -rf "$d"
        _shield_set "$SHIELD_DIR/status" "upd=$(_shield_now)" "upderr=${SHIELD_ERR}" "rej=" "rejwhy="
        shield_log "$(bi "списки не скачались: ${SHIELD_ERR}" "the lists did not download: ${SHIELD_ERR}")"
        [ -n "$q" ] || err "$(bi "Списки не скачались: ${SHIELD_ERR}. Работает прежний список." "The lists did not download: ${SHIELD_ERR}. The previous list keeps working.")"
        return 1
    fi
    if ! shield_accept "$d"; then
        rm -rf "$d"
        _shield_set "$SHIELD_DIR/status" "upd=$(_shield_now)" "upderr=" "rej=$(_shield_now)" "rejwhy=${SHIELD_ERR}"
        shield_log "$(bi "список отклонён: ${SHIELD_ERR}; работает прежний" "the list is rejected: ${SHIELD_ERR}; the previous one keeps working")"
        [ -n "$q" ] || err "$(bi "Новый список не прошёл проверку: ${SHIELD_ERR}. Работает прежний." "The new list failed the check: ${SHIELD_ERR}. The previous one keeps working.")"
        return 1
    fi
    rm -rf "$d"
    # Причина отказа ВК живёт до следующего принятого списка: хеш тот же
    # (rc 2) или сеть упала — она по-прежнему верна.
    _shield_set "$SHIELD_DIR/status" "upd=$(_shield_now)" "upderr=" "rej=" "rejwhy=" "vkwhy=${SHIELD_VKERR}"
    if [ -z "$q" ] && [ -n "$SHIELD_VKERR" ]; then
        if [ -n "$SHIELD_VKNONE" ]; then warn "$(bi "Новый список ВК не прошёл проверку: ${SHIELD_VKERR}. Прежнего нет — ВК пуст, список сканеров обновлён." "The new VK list failed the check: ${SHIELD_VKERR}. There is no previous one — VK is empty, the scanner list is updated.")"
        else warn "$(bi "Новый список ВК не прошёл проверку: ${SHIELD_VKERR}. Работает прежний ВК, список сканеров обновлён." "The new VK list failed the check: ${SHIELD_VKERR}. The previous VK keeps working, the scanner list is updated.")"; fi
    fi
    if ! shield_apply; then
        shield_log "$(bi "новый список не применился: ${SHIELD_ERR}" "the new list did not apply: ${SHIELD_ERR}")"
        [ -n "$q" ] || err "$(bi "Новый список не применился: ${SHIELD_ERR}" "The new list did not apply: ${SHIELD_ERR}")"
        shield_check --quiet
        return 1
    fi
    [ -n "$q" ] || ok "$(bi "Списки обновлены: $(_shield_nets "$(_shield_num "$SHIELD_DIR/status" nets)")." "The lists are updated: $(_shield_nets "$(_shield_num "$SHIELD_DIR/status" nets)").")"
    return 0
}

_shield_enabled() {
    [ "$(_shield_get "$SHIELD_DIR/settings" scan)" = 1 ] || [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ]
}
# Такт таймера (раз в час) и службы при загрузке: после загрузки —
# применить сохранённое; порты SSH или адреса сменились — пересобрать;
# правила пропали — восстановить; список старше суток — обновить.
shield_tick() {
    local d age up fp0 a0 g0
    shield_installed || return 0
    _shield_lock 600 || return 0
    if [ ! -e "$SHIELD_RUN" ]; then
        # После загрузки — только сохранённое, без сети: служба oneshot в
        # multi-user.target, и скачивание держало бы загрузку минутами.
        # Список обновит следующий такт.
        if shield_apply; then shield_log "$(bi "применено после загрузки" "applied after boot")"
        else shield_log "$(bi "после загрузки не применилось: ${SHIELD_ERR}" "did not apply after boot: ${SHIELD_ERR}")"; fi
        _shield_boot_mark
        shield_check --quiet
        _shield_unlock
        return 0
    fi
    # Статистика — до проверки: пересборка обнулила бы счётчики (снимок
    # перед ней делает и shield_apply).
    _shield_stats_tick
    # Порты SSH и адреса сверяет сама проверка (_shield_fp_sync).
    fp0=$(_shield_fp_now)
    shield_check --quiet
    a0=$(_shield_get "$SHIELD_DIR/status" applied) || a0=""
    g0=$(_shield_get "$SHIELD_DIR/status" ghhit) || g0=""
    if _shield_enabled; then
        d=$(_shield_num "$SHIELD_DIR/lists/meta" date)
        age=$(( $(_shield_now) - d ))
        up=$(_shield_uptime)
        # Первые 10 минут после загрузки — без сети: такт зовёт и слежка за
        # sshd.pid (sshd стартует при загрузке), а сеть может быть ещё не
        # поднята. Список обновит таймер (OnBootSec=15min).
        if [ "$up" -lt 600 ]; then
            [ "$age" -ge 86400 ] && shield_log "$(bi "обновление отложено: ${up} с после загрузки" "the update is postponed: ${up} s after boot")"
        else
            # Список старше суток — обновить; подписей сетей нет (принят до
            # 1.2.4, REVIEW-6 №7и) — тоже, не дожидаясь суток.
            { [ "$age" -ge 86400 ] || [ ! -e "$SHIELD_DIR/lists/owners" ]; } && shield_update --quiet
            _shield_tick_gh
        fi
    fi
    # В конце — одна сверка и одна запись status, и только если за такт
    # что-то сменилось: порты или адреса (пока такт ходил в сеть — минуты
    # при закрытом GitHub, — слежка за настройками SSH сливалась с ним, К2-3d),
    # правила пересобраны обновлением, находка про GitHub в ВК. Иначе итог
    # начальной проверки верен, а повтор при сломанном nft только множил бы
    # строки «не пересобрались» (REVIEW-3 №3).
    if [ "$(_shield_fp_now)" != "$fp0" ] || [ "$(_shield_get "$SHIELD_DIR/status" applied)" != "$a0" ] \
       || [ "$(_shield_get "$SHIELD_DIR/status" ghhit)" != "$g0" ]; then
        shield_check --quiet
    fi
    _shield_unlock
    return 0
}
# Такт при включённом ВК: принятый ВК против адресов GitHub (REVIEW-3 №2б).
# ВК, принятый без сверки (адреса не разрешились) или до смены адресов
# GitHub, режет сервер от обновлений, и обновление само это не вылечит.
# Итог — поле ghhit в status («сеть адрес»; его читает проверка); в журнал —
# только перемена. Адреса не разрешились — прежний итог остаётся.
_shield_tick_gh() {
    local rc h h0
    [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ] || return 0
    h0=$(_shield_get "$SHIELD_DIR/status" ghhit) || h0=""
    if _shield_vk_empty; then h=""
    else
        _shield_gh_resolve
        _shield_gh_note || return 0
        _shield_vk_gh "$SHIELD_DIR/lists/vk4" "$SHIELD_DIR/lists/vk6"; rc=$?
        case "$rc" in
            0) h="" ;;
            7) h="${SHIELD_GHNET} ${SHIELD_GHADDR}" ;;
            *) shield_log "$(bi "список ВК не сверить с адресами GitHub (код ${rc})" "cannot match the VK list against the GitHub addresses (code ${rc})")"; return 0 ;;
        esac
    fi
    [ "$h" = "$h0" ] && return 0
    _shield_set "$SHIELD_DIR/status" "ghhit=${h}"
    if [ -n "$h" ]; then shield_log "$(bi "в списке ВК сеть ${SHIELD_GHNET} с адресом GitHub ${SHIELD_GHADDR} — сервер не дойдёт до обновлений: выключите ВК или добавьте адрес в исключения" "the VK list has ${SHIELD_GHNET} holding the GitHub address ${SHIELD_GHADDR} — the server cannot reach updates: turn VK off or add the address to the exclusions")"
    else shield_log "$(bi "адресов GitHub в списке ВК больше нет" "the VK list no longer holds GitHub addresses")"; fi
}
# Отметка «после загрузки уже применено» — пустой файл в /run, только root.
_shield_boot_mark() { ( umask 077; : > "$SHIELD_RUN" ) 2>/dev/null; }
# Секунд с загрузки; не прочесть — «давно» (сети не мешать).
_shield_uptime() {
    local u=""
    if [ -n "${GOINST_TEST:-}" ]; then u="${GOINST_SHIELD_UPTIME:-999999}"
    else read -r u _ 2>/dev/null < /proc/uptime || u=""; u="${u%%.*}"; fi
    case "$u" in ''|*[!0-9]*) u=999999 ;; esac
    printf '%s' "$u"
}

# Единственное место, где защита зовёт apt: ровно пакет nftables, без
# рекомендованных; служба nftables не включается и не трогается (её
# /etc/nftables.conf начинается с flush ruleset и снёс бы чужие правила).
shield_apt_nft() {
    DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install --no-install-recommends nftables >/dev/null 2>&1 && return 0
    DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install --no-install-recommends nftables >/dev/null 2>&1
}
# Можно ли здесь вообще: python3, systemd, nft работает или его можно
# поставить (не в контейнере). rc 1 — нельзя, SHIELD_ERR словами.
shield_support() {
    SHIELD_ERR=""
    if ! command -v python3 >/dev/null 2>&1; then SHIELD_ERR=$(bi "нет python3 — проверять списки нечем" "python3 is missing — nothing to check the lists with")
    elif ! command -v systemctl >/dev/null 2>&1; then SHIELD_ERR=$(bi "нет systemd — некому обновлять списки и применять правила после загрузки" "no systemd — nothing to update the lists and apply the rules after boot")
    elif _shield_have_nft; then
        _shield_nft list tables >/dev/null 2>&1 || SHIELD_ERR=$(bi "nft есть, но не работает: ядро или контейнер без nftables" "nft is here but does not work: the kernel or the container has no nftables")
    elif osup_container; then SHIELD_ERR=$(bi "сервер — контейнер (${OSUP_VIRT}): свои правила nft в нём не завести" "the server is a container (${OSUP_VIRT}): it cannot have its own nft rules")
    elif ! command -v apt-get >/dev/null 2>&1; then SHIELD_ERR=$(bi "нет nft и нет apt-get, чтобы его поставить" "no nft and no apt-get to set it up")
    fi
    [ -z "$SHIELD_ERR" ]
}
_shield_unsupported() {  # отметка «не поддерживается»: больше не предлагать
    mkdir -p "$SHIELD_DIR" 2>/dev/null && chmod 700 "$SHIELD_DIR" 2>/dev/null
    printf 'unsupported %s\n' "$(_shield_clean "$1")" > "$SHIELD_DIR/declined" 2>/dev/null; chmod 600 "$SHIELD_DIR/declined" 2>/dev/null
    shield_log "$(bi "сервер не поддерживает: $1" "the server does not support it: $1")"
}

# Копия скрипта для таймера — как у обновления Ubuntu (os-upgrade/runner.sh):
# юнит зовёт её, а не goinstall. goinstall подменяет `--self-update main` (а
# до 1.2.0 и self_install при `bash <(curl …)` ставил ветку main) — тогда
# `--shield tick` отвечал бы usage, таймер падал бы каждый час, а после
# перезагрузки правил не было бы. Источник — файл ЭТОЙ версии с защитой:
# сначала goinstall, потом запущенный файл. Копия идёт за goinstall: две
# сборки с одним номером (К5-11, стенд 03.11) иначе давали смешанную
# установку — копия из запущенного файла, goinstall прежний, — и «пинг-понг»
# копии между ними. goinstall другой версии или его нет — запущенный файл
# (из bash <(curl …) это не файл). Копию новее не трогаем (запуск старой
# версии из файла).
shield_runner_src() {
    local f
    for f in "$GOINST_BIN" "$GOINST_SELF_PATH"; do
        [ -f "$f" ] || continue
        grep -qx "GOINST_VERSION=\"${GOINST_VERSION}\"" "$f" 2>/dev/null || continue
        grep -q '^shield_cli()' "$f" 2>/dev/null || continue
        printf '%s' "$f"; return 0
    done
    return 1
}
# shield_runner_put — положить копию. rc 0 — на месте копия этой версии;
# 2 — оставлена прежняя рабочая (новее этой или источника нет): юниты тогда
# не переписываем; 1 — нет ни источника, ни прежней копии (SHIELD_ERR).
shield_runner_put() {
    local src rv
    _shield_paths
    if ! src=$(shield_runner_src); then
        [ -f "$SHIELD_RUNNER" ] && grep -q '^shield_cli()' "$SHIELD_RUNNER" 2>/dev/null && return 2
        SHIELD_ERR="$(bi "нет файла скрипта версии ${GOINST_VERSION} для таймера" "no ${GOINST_VERSION} script file for the timer"): $(self_fix_hint)"
        return 1
    fi
    if [ -f "$SHIELD_RUNNER" ]; then
        cmp -s "$src" "$SHIELD_RUNNER" && return 0
        rv=$(grep -m1 '^GOINST_VERSION="' "$SHIELD_RUNNER" 2>/dev/null) || rv=""
        rv="${rv#*\"}"; rv="${rv%\"*}"
        if [ -n "$rv" ] && ver_newer "$GOINST_VERSION" "$rv" && grep -q '^shield_cli()' "$SHIELD_RUNNER" 2>/dev/null; then return 2; fi
    fi
    # Рядом и переставить: идущий такт дочитывает прежний файл (bash читает
    # скрипт по ходу), mv подменяет имя, а не содержимое.
    if ! { cp -f "$src" "$SHIELD_RUNNER.new" 2>/dev/null && chmod 700 "$SHIELD_RUNNER.new" && mv -f "$SHIELD_RUNNER.new" "$SHIELD_RUNNER"; }; then
        rm -f "$SHIELD_RUNNER.new" 2>/dev/null
        SHIELD_ERR=$(bi "не записать ${SHIELD_RUNNER}" "cannot write ${SHIELD_RUNNER}"); return 1
    fi
    shield_log "$(bi "копия скрипта для таймера: версия ${GOINST_VERSION}" "the script copy for the timer: version ${GOINST_VERSION}")"
    return 0
}

# Юниты: служба (такт), таймер (раз в час), слежка за настройками SSH (порт
# сменился — такт сразу, а не через час). Слежка смотрит и /run/sshd.pid: sshd
# пишет его при старте и перезапуске (и ssh.socket, перезапуская ssh.service),
# уже слушая новые порты, — так прежний порт уходит из правил сразу, а не
# следующей сверкой (настройки правят ДО перезапуска). Все три — только при живой копии
# (ConditionPathExists): после --uninstall прежней версии (каталог снят, юниты
# остались) таймер и слежка после загрузки не запускаются, служба
# пропускается, а не падает.
# Сеть загрузке не нужна (такт после загрузки — только сохранённое), поэтому
# network-online только порядком, без Wants: тянуть его ради защиты — задержать
# загрузку там, где его никто не ждёт.
_shield_unit_text() {  # _shield_unit_text <service|timer|path>
    case "$1" in
        service) cat <<UNIT
[Unit]
Description=goInstaller: защита от сканеров — применить правила и проверить
After=network.target network-online.target
ConditionPathExists=${SHIELD_RUNNER}

[Service]
Type=oneshot
Nice=10
TimeoutStartSec=15min
ExecStart=/bin/bash ${SHIELD_RUNNER} --shield tick

[Install]
WantedBy=multi-user.target
UNIT
        ;;
        timer) cat <<UNIT
[Unit]
Description=goInstaller: защита от сканеров — проверка раз в час
ConditionPathExists=${SHIELD_RUNNER}

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
UNIT
        ;;
        path) cat <<UNIT
[Unit]
Description=goInstaller: защита от сканеров — настройки SSH сменились
ConditionPathExists=${SHIELD_RUNNER}

[Path]
PathChanged=/etc/ssh/sshd_config
PathChanged=/etc/ssh/sshd_config.d
PathChanged=/etc/systemd/system/ssh.socket
PathChanged=/etc/systemd/system/ssh.socket.d
PathChanged=/run/sshd.pid
Unit=${SHIELD_UNIT}.service

[Install]
WantedBy=paths.target
UNIT
        ;;
    esac
}
# shield_units_write [sync] — записать и включить. sync — только если текст
# сменился (переход с прежних юнитов, новая версия).
shield_units_write() {
    local u f ch=0
    _shield_paths
    mkdir -p "$SHIELD_UNITD" 2>/dev/null || return 1
    for u in service timer path; do
        f="$SHIELD_UNITD/$SHIELD_UNIT.$u"
        [ "$(_shield_unit_text "$u")" = "$(cat "$f" 2>/dev/null)" ] && continue
        _shield_unit_text "$u" > "$f" 2>/dev/null && chmod 644 "$f" 2>/dev/null
        ch=1
    done
    [ "${1:-}" = sync ] && [ "$ch" = 0 ] && return 0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$SHIELD_UNIT.service" "$SHIELD_UNIT.timer" "$SHIELD_UNIT.path" >/dev/null 2>&1 || true
        systemctl start "$SHIELD_UNIT.timer" "$SHIELD_UNIT.path" >/dev/null 2>&1 || true
    fi
    [ "${1:-}" = sync ] && shield_log "$(bi "юниты переписаны под версию ${GOINST_VERSION}" "the units are rewritten for version ${GOINST_VERSION}")"
    return 0
}
# shield_sync — защита стоит: копия и юниты под эту версию. Зовётся при
# старте меню и --install (shield_offer), из --watch и команд --shield.
# Занято тактом — в другой раз.
shield_sync() {
    _shield_paths
    shield_installed || return 0
    _shield_lock 0 || return 0
    if shield_runner_put; then shield_units_write sync; fi
    _shield_unlock
    return 0
}
# Самообновление или self_install поставили goinstall без защиты: правила и
# таймер остаются (их ведёт копия), сказать, как снять.
shield_self_update_note() {  # shield_self_update_note <новый скрипт>
    _shield_paths
    shield_installed || return 0
    grep -q '^shield_cli()' "$1" 2>/dev/null && return 0
    warn "$(bi "В этой версии goInstaller нет защиты от сканеров. Защита продолжает работать: таймер запускает свою копию ${SHIELD_RUNNER}. Снять её: bash ${SHIELD_RUNNER} --shield remove --yes — и до удаления goInstaller: удаление этой версией защиту не снимет (правила останутся до перезагрузки, юниты ${SHIELD_UNIT} — в ${SHIELD_UNITD})." "This goInstaller version has no scanner protection. The protection keeps working: the timer runs its own copy ${SHIELD_RUNNER}. To remove it: bash ${SHIELD_RUNNER} --shield remove --yes — and do it before removing goInstaller: removing it with this version does not remove the protection (the rules stay until a reboot, the ${SHIELD_UNIT} units stay in ${SHIELD_UNITD}).")"
    shield_log "$(bi "goinstall заменён версией без защиты; защиту ведёт ${SHIELD_RUNNER}" "goinstall is replaced by a version without the protection; ${SHIELD_RUNNER} keeps it running")"
    return 0
}
# Снять правила и юниты (файлы остаются — их убирает вызывающий).
shield_teardown() {
    _shield_paths
    local u f any=0
    for u in timer path service; do [ -e "$SHIELD_UNITD/$SHIELD_UNIT.$u" ] && any=1; done
    if command -v systemctl >/dev/null 2>&1 && [ "$any" = 1 ]; then
        systemctl disable --now "$SHIELD_UNIT.timer" "$SHIELD_UNIT.path" >/dev/null 2>&1 || true
        systemctl disable "$SHIELD_UNIT.service" >/dev/null 2>&1 || true
        for u in timer path service; do rm -f "$SHIELD_UNITD/$SHIELD_UNIT.$u"; done
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    for u in timer path service; do f="$SHIELD_UNITD/$SHIELD_UNIT.$u"; rm -f "$f" 2>/dev/null; done
    rm -f "$SHIELD_RUN" 2>/dev/null
    if _shield_have_nft && _shield_nft -t list table inet "$SHIELD_TABLE" >/dev/null 2>&1; then
        _shield_nft delete table inet "$SHIELD_TABLE" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# shield_install — поставить (согласие уже получено): списки, nftables при
# нужде, правила, юниты. rc 0; 1 — не вышло сейчас (сказано, предложим
# снова); 2 — сервер не поддерживает (записано, больше не предлагаем).
shield_install() {
    local d rc h
    _shield_paths
    if ! shield_support; then err "$(bi "Защиту от сканеров здесь не поставить: ${SHIELD_ERR}." "Scanner protection cannot be set up here: ${SHIELD_ERR}.")"; _shield_unsupported "$SHIELD_ERR"; return 2; fi
    if ! shield_runner_src >/dev/null && ! { [ -f "$SHIELD_RUNNER" ] && grep -q '^shield_cli()' "$SHIELD_RUNNER" 2>/dev/null; }; then
        err "$(bi "Таймеру защиты нечего запускать: нет файла скрипта версии ${GOINST_VERSION} (скрипт запущен не из файла, а goinstall другой версии). Чтобы поставить защиту, $(self_fix_hint)" "The protection timer would have nothing to run: no ${GOINST_VERSION} script file (the script is not running from a file, and goinstall is another version). To set up the protection, $(self_fix_hint)")"
        return 1
    fi
    mkdir -p "$SHIELD_DIR" && chmod 700 "$SHIELD_DIR" || { err "$(bi "Не создать ${SHIELD_DIR}." "Cannot create ${SHIELD_DIR}.")"; return 1; }
    _shield_lock_say || return 1
    d=$(mktemp -d "${TMPDIR:-/tmp}/goinst-shield.XXXXXX") || { _shield_unlock; return 1; }
    say "$(bi "Скачиваю списки AS_Network_List…" "Downloading the AS_Network_List lists…")"
    SHIELD_SAY=1 shield_fetch "$d" ""; rc=$?
    if [ "$rc" -ne 0 ]; then
        err "$(bi "Списки не скачались: ${SHIELD_ERR}. Защиту не ставлю — предложу в следующий раз." "The lists did not download: ${SHIELD_ERR}. Not setting up the protection — I will offer it next time.")"
        shield_log "$(bi "установка: списки не скачались: ${SHIELD_ERR}" "install: the lists did not download: ${SHIELD_ERR}")"
        rm -rf "$d"; _shield_unlock; return 1
    fi
    if ! shield_accept "$d"; then
        err "$(bi "Список не прошёл проверку: ${SHIELD_ERR}. Защиту не ставлю — предложу в следующий раз." "The list failed the check: ${SHIELD_ERR}. Not setting up the protection — I will offer it next time.")"
        shield_log "$(bi "установка: список отклонён: ${SHIELD_ERR}" "install: the list is rejected: ${SHIELD_ERR}")"
        rm -rf "$d"; _shield_unlock; return 1
    fi
    rm -rf "$d"
    if ! _shield_have_nft; then
        say "$(bi "Ставлю пакет nftables…" "Installing the nftables package…")"
        # apt ждёт замок до 5 минут на вызов (их до трёх): молча это
        # выглядит зависанием. Кто держит — тот же разбор, что у обновления ОС.
        h=$(osup_lock_holder); h=$(_shield_clean "$h")
        [ -n "$h" ] && say "$(bi "Пакетами сейчас занят процесс ${h} — жду, пока он отпустит замок apt (до 15 минут)." "Packages are busy with process ${h} — waiting for it to release the apt lock (up to 15 minutes).")"
        if ! shield_apt_nft || ! _shield_have_nft; then
            err "$(bi "Пакет nftables не встал (apt-get). Защиту не ставлю — предложу в следующий раз." "apt-get failed on the nftables package. Not setting up the protection — I will offer it next time.")"
            _shield_unlock; return 1
        fi
        shield_log "$(bi "поставлен пакет nftables" "the nftables package is installed")"
    fi
    if ! _shield_nft list tables >/dev/null 2>&1; then
        SHIELD_ERR=$(bi "nft не работает: ядро или контейнер без nftables" "nft does not work: the kernel or the container has no nftables")
        err "$(bi "Защиту от сканеров здесь не поставить: ${SHIELD_ERR}." "Scanner protection cannot be set up here: ${SHIELD_ERR}.")"
        _shield_unsupported "$SHIELD_ERR"; _shield_unlock; return 2
    fi
    shield_runner_put; rc=$?
    if [ "$rc" = 1 ]; then
        err "$(bi "Защиту не ставлю: ${SHIELD_ERR}." "Not setting up the protection: ${SHIELD_ERR}.")"
        _shield_unlock; return 1
    fi
    # ВК по умолчанию включён (решение владельца 03.11.2026) — только у новой
    # установки, где файла настроек ещё нет. Он уже есть (два «on» наперегонки,
    # экран «Аркады» до чужой установки) — выбор ВК из него не трогаем: нет
    # ключа vk — значит «выкл», прежнее умолчание. Стоящую защиту «on» сюда не
    # ведёт: там shield_toggle scan 1, ВК как был.
    local vk=1 vkwant new="" mwhy=""
    if [ -f "$SHIELD_DIR/settings" ]; then vk=$(_shield_get "$SHIELD_DIR/settings" vk) || vk=0; else new=1; fi
    [ "$vk" = 1 ] || vk=0
    vkwant="$vk"
    # Пустой ВК не включаем (REVIEW-3 №1): правила без сетей выглядели бы рабочими.
    _shield_vk_empty && vk=0
    # Умолчание новой установки — только по принятому сейчас списку ВК: при
    # отказе работает прежний, не сверенный с этим отказом (REVIEW-5 №2). И не
    # там, где goVLESS маскируется под сайт из ВК (REVIEW-5 №1).
    if [ -n "$new" ] && [ "$vk" = 1 ]; then
        if [ -n "$SHIELD_VKERR" ]; then vk=0
        else
            _shield_mask_vk
            case "$?" in
                7) vk=0; mwhy=$(bi "${SHIELD_MASKWHY}. С закрытым ВК VLESS этого сервера перестал бы работать — «ВК: не выпускать» оставляю выключенным; включить — пункт 2 в меню «Защита от сканеров», сменив домен маскировки (команда govless) на сайт вне ВК." "${SHIELD_MASKWHY}. With VK closed, this server's VLESS would stop working — “VK: block outbound” stays off; to turn it on, change the masking domain (the govless command) to a site outside VK, then use item 2 in the “Scanner protection” menu.") ;;
                2) vk=0; mwhy=$(bi "${SHIELD_MASKWHY}. Если это сайт из сетей ВК, закрытый ВК остановил бы VLESS — «ВК: не выпускать» оставляю выключенным; включить — пункт 2 в меню «Защита от сканеров», если сайт не из ВК." "${SHIELD_MASKWHY}. If it is a site in VK networks, closing VK would stop VLESS — “VK: block outbound” stays off; turn it on with item 2 in the “Scanner protection” menu if the site is not VK.") ;;
            esac
        fi
    fi
    printf 'scan=1\nvk=%s\n' "$vk" > "$SHIELD_DIR/settings"; chmod 600 "$SHIELD_DIR/settings"
    if ! shield_apply; then
        err "$(bi "Сервер не принял правила nft: ${SHIELD_ERR}. Защиту не ставлю." "The server did not accept the nft rules: ${SHIELD_ERR}. Not setting up the protection.")"
        rm -f "$SHIELD_DIR/settings"; shield_teardown
        _shield_unsupported "$SHIELD_ERR"; _shield_unlock; return 2
    fi
    shield_units_write
    _shield_boot_mark
    rm -f "$SHIELD_DIR/declined"
    # Причина отказа ВК — в status, как у обновления (REVIEW-3 №1): её видят
    # status, меню и «Аркада», а «vk on» отказывает словами.
    _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=ok" "why=" "upd=$(_shield_now)" "vkwhy=${SHIELD_VKERR}"
    shield_log "$(bi "защита включена" "the protection is on")"
    _shield_unlock
    ok "$(bi "Защита от сканеров включена: $(_shield_nets "$(_shield_num "$SHIELD_DIR/status" nets)") не увидят портов этого сервера. SSH открыт." "Scanner protection is on: $(_shield_nets "$(_shield_num "$SHIELD_DIR/status" nets)") will not see this server's ports. SSH stays open.")"
    if [ -n "$SHIELD_VKERR" ]; then
        if _shield_vk_empty; then warn "$(bi "Список ВК не прошёл проверку: ${SHIELD_VKERR}. Прежнего нет — ВК пуст: «ВК: не выпускать» оставляю выключенным. Включить — пункт 2 в меню «Защита от сканеров», когда придёт исправный список." "The VK list failed the check: ${SHIELD_VKERR}. There is no previous one — VK is empty: “VK: block outbound” stays off. Turn it on with item 2 in the “Scanner protection” menu once a sound list arrives.")"
        elif [ -n "$new" ]; then warn "$(bi "Список ВК не прошёл проверку: ${SHIELD_VKERR}. «ВК: не выпускать» оставляю выключенным. Включить — пункт 2 в меню «Защита от сканеров», когда придёт исправный список." "The VK list failed the check: ${SHIELD_VKERR}. “VK: block outbound” stays off. Turn it on with item 2 in the “Scanner protection” menu once a sound list arrives.")"
        else warn "$(bi "Список ВК не прошёл проверку: ${SHIELD_VKERR}. Работает прежний ВК." "The VK list failed the check: ${SHIELD_VKERR}. The previous VK keeps working.")"; fi
    elif [ "$vkwant" = 1 ] && _shield_vk_empty; then
        warn "$(bi "Список ВК пуст — закрывать нечего: «ВК: не выпускать» оставляю выключенным. Включить — пункт 2 в меню «Защита от сканеров», когда придёт непустой список." "The VK list is empty — nothing to block: “VK: block outbound” stays off. Turn it on with item 2 in the “Scanner protection” menu once a non-empty list arrives.")"
    fi
    [ -n "$mwhy" ] && warn "$mwhy"
    # Сам сервер тоже не ходит в сети ВК (vk_output) — сказать при включении,
    # списком: что не будет работать (решение владельца 03.11.2026).
    [ "$vk" = 1 ] && _shield_vk_say on
    say "$(bi "Списки обновляются сами раз в сутки. «ВК: не выпускать» и исключения — в меню «Защита от сканеров»." "The lists update themselves daily. “VK: block outbound” and exclusions are in the “Scanner protection” menu.")"
    return 0
}

_shield_nets() {  # _shield_nets <N> → «N сеть|сети|сетей»
    local n="${1:-0}" w
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "${LANG_CODE:-ru}" = en ]; then if [ "$n" = 1 ]; then w=network; else w=networks; fi
    else
        case $(( n % 100 )) in
            11|12|13|14) w=сетей ;;
            *) case $(( n % 10 )) in 1) w=сеть ;; 2|3|4) w=сети ;; *) w=сетей ;; esac ;;
        esac
    fi
    printf '%s %s' "$n" "$w"
}

# shield_state [--live] — состояние для меню, сводки и status.
# → SHS_ST (none|off|ok|bad), SHS_WHY, SHS_SCAN, SHS_VK, SHS_N, SHS_NX, SHS_DATE
# (ДД.ММ), SHS_AGE (с), SHS_CHECK, SHS_DROPS, SHS_REJS, SHS_REJ, SHS_NEX, SHS_NBL,
# SHS_WHYS (причина ✗ коротко — для 46 колонок),
# SHS_UPDERR (почему не скачалось последнее обновление), SHS_VKREJ (почему
# отклонён последний список ВК — оставлен прежний), SHS_VKEMPTY (1 — список
# ВК пуст: прежнего не было), SHS_SINCE (с какого
# времени счётчики: правила пересобраны — счёт с нуля),
# SHS_TEXT/SHS_TOK — строка меню. --live спрашивает nft и при поломке
# восстанавливает (как такт таймера).
shield_state() {
    local st m d c now r
    _shield_paths
    SHS_ST=none; SHS_WHY=""; SHS_SCAN=0; SHS_VK=0; SHS_N=0; SHS_NX=0; SHS_DATE=""; SHS_AGE=0; SHS_CHECK=""
    SHS_DROPS=""; SHS_REJS=""; SHS_REJ=""; SHS_NEX=0; SHS_NBL=0; SHS_UNSUP=""; SHS_UPDERR=""; SHS_SINCE=""; SHS_VKREJ=""; SHS_WHYS=""; SHS_VKEMPTY=0
    st="$SHIELD_DIR/status"; m="$SHIELD_DIR/lists/meta"
    if [ ! -f "$SHIELD_DIR/settings" ]; then
        r=$(head -1 "$SHIELD_DIR/declined" 2>/dev/null) || r=""
        case "$r" in unsupported*) SHS_UNSUP="${r#unsupported }" ;; esac
        _shield_text; return 0
    fi
    [ "$(_shield_get "$SHIELD_DIR/settings" scan)" = 1 ] && SHS_SCAN=1
    [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ] && SHS_VK=1
    now=$(_shield_now); d=$(_shield_num "$m" date)
    [ "$d" -gt 0 ] && { SHS_DATE=$(printf '%(%d.%m)T' "$d"); SHS_AGE=$(( now - d )); }
    SHS_N=$(_shield_num "$st" nets); SHS_NX=$(_shield_num "$st" nx)
    c=$(_shield_num "$st" check); [ "$c" -gt 0 ] && SHS_CHECK=$(printf '%(%d.%m %H:%M)T' "$c")
    r=$(_shield_num "$st" rej); [ "$r" -gt 0 ] && [ "$r" -ge "$d" ] && SHS_REJ=$(_shield_get "$st" rejwhy)
    SHS_UPDERR=$(_shield_get "$st" upderr) || SHS_UPDERR=""
    SHS_VKREJ=$(_shield_get "$st" vkwhy) || SHS_VKREJ=""
    _shield_vk_empty && SHS_VKEMPTY=1
    [ -s "$SHIELD_DIR/exclude" ] && SHS_NEX=$(grep -c . "$SHIELD_DIR/exclude")
    [ -s "$SHIELD_DIR/block" ] && SHS_NBL=$(grep -c . "$SHIELD_DIR/block")
    if [ "$SHS_SCAN" = 0 ] && [ "$SHS_VK" = 0 ]; then SHS_ST=off; _shield_text; return 0; fi
    SHS_ST=ok
    if [ "${1:-}" = --live ]; then
        # Проверить делом (порты SSH, правила на месте, восстановить), если
        # не занято таймером; занято — живы ли правила, остальное по файлу.
        if _shield_lock 0; then
            shield_check --quiet
            _shield_unlock
            [ "$(_shield_get "$st" result)" = fail ] && { SHS_ST=bad; SHS_WHY=$(_shield_get "$st" why); SHS_WHYS=$(_shield_why_short "$(_shield_get "$st" wk)"); }
        elif ! shield_live_ok || [ "$(_shield_get "$st" result)" = fail ]; then
            SHS_ST=bad; SHS_WHY=$(_shield_get "$st" why); SHS_WHYS=$(_shield_why_short "$(_shield_get "$st" wk)")
            [ -n "$SHS_WHY" ] || { SHS_WHY=$(_shield_live_text "$SHIELD_LIVE"); SHS_WHYS=$(_shield_why_short rules); }
        fi
    elif [ "$(_shield_get "$st" result)" = fail ]; then SHS_ST=bad; SHS_WHY=$(_shield_get "$st" why); SHS_WHYS=$(_shield_why_short "$(_shield_get "$st" wk)")
    fi
    if [ "$SHS_ST" = ok ] && [ "$SHS_AGE" -gt 259200 ]; then
        SHS_ST=bad; SHS_WHY=$(_shield_stale_why "$d"); SHS_WHYS=$(_shield_why_short stale)
    fi
    c=$(_shield_num "$st" applied); [ "$c" -gt 0 ] && SHS_SINCE=$(printf '%(%d.%m %H:%M)T' "$c")
    _shield_text
}
_shield_text() {
    case "$SHS_ST" in
        ok)  SHS_TOK=ok
             if [ "$SHS_SCAN" = 1 ]; then SHS_TEXT="$(bi "вкл" "on") · $(_shield_nets "$SHS_N") · $(bi "список от" "list from") ${SHS_DATE:-—}"
             else SHS_TEXT="$(bi "ВК вкл · список от" "VK on · list from") ${SHS_DATE:-—}"; fi ;;
        bad) SHS_TOK=err; SHS_TEXT="✗ $(bi "не работает" "not working")" ;;
        *)   SHS_TOK=muted; SHS_TEXT=$(bi "выкл" "off") ;;
    esac
}
# Строка главного меню: короткое состояние в колонку, остальное — в пояснение
# (колонка состояния общая с продуктами, длинная строка раздвинула бы её).
# → SHS_MST («g:вкл»), SHS_MSUB.
shield_menu_line() {
    shield_state --live
    case "$SHS_ST" in
        ok)   SHS_MST="g:$(bi "вкл" "on")"
              if [ "$SHS_SCAN" = 1 ]; then SHS_MSUB="$(_shield_nets "$SHS_N") · $(bi "список от" "list from") ${SHS_DATE:-—}"
              else SHS_MSUB="$(bi "ВК · список от" "VK · list of") ${SHS_DATE:-—}"; fi ;;
        bad)  SHS_MST="r:✗ $(bi "не работает" "not working")"; SHS_MSUB="${SHS_WHY}" ;;
        off)  SHS_MST="d:$(bi "выкл" "off")"; SHS_MSUB=$(bi "сканеры и ВК выключены" "scanners and VK are off") ;;
        *)    SHS_MST="d:$(bi "выкл" "off")"; SHS_MSUB=$(bi "сканеры не увидят портов сервера" "scanners will not see the server's ports") ;;
    esac
}
# Причина ✗ коротко — третье поле замечания, строка на 46 колонках (там нет
# места для полной причины и команды): «Защита от сканеров: » + до 22 знаков.
_shield_why_short() {  # _shield_why_short <stale|gh|ports|rules|…>
    case "$1" in
        stale) bi "список старше 3 суток" "list older than 3 days" ;;
        gh)    bi "ВК закрыл GitHub" "VK blocks GitHub" ;;
        ports) bi "правила не пересобраны" "rules not rebuilt" ;;
        rules) bi "правила не применились" "rules not applied" ;;
        *)     bi "не работает" "not working" ;;
    esac
}
# Замечание для меню и сводки при входе (как у компонентов) → SHIELD_PROBS.
shield_probs() {
    SHIELD_PROBS=()
    [ "${SHS_ST:-}" = bad ] || return 0
    SHIELD_PROBS+=("$(bi "Защита от сканеров" "Scanner protection")|$(bi "не работает" "not working"): ${SHS_WHY:-?}|$(bi "Защита от сканеров" "Scanner protection"): ${SHS_WHYS:-$(bi "не работает" "not working")}|goinstall --shield check|err")
}

# Заметка «список ВК отклонён» — продолжение после «отклонён»: прежнего нет —
# ВК пуст (REVIEW-3 №1); ВК выключен — с пометкой, и места показывают её
# серым, а не жёлтым (REVIEW-3 №5).
_shield_vkrej_tail() {
    if [ "${SHS_VKEMPTY:-0}" = 1 ]; then bi ", прежнего нет — ВК пуст" ", there is no previous one — VK is empty"
    else bi ", оставлен прежний" ", the previous one is kept"; fi
    [ "${SHS_VK:-0}" = 1 ] || bi " (ВК выключен)" " (VK is off)"
}
shield_status_print() {
    local w
    shield_state --live
    print_header "$(bi "Защита от сканеров" "Scanner protection")"
    case "$SHS_ST" in
        none) say "$(bi "Не стоит. Включить: goinstall --shield on" "Not installed. To turn on: goinstall --shield on")"
              [ -n "$SHS_UNSUP" ] && warn "$(bi "Раньше не поставилась:" "Earlier it did not install:") ${SHS_UNSUP}"
              return 3 ;;
        off)  say "$(bi "Выключена: и сканеры, и ВК. Включить: goinstall --shield on" "Off: both scanners and VK. To turn on: goinstall --shield on")" ;;
        ok)   ok "$SHS_TEXT" ;;
        bad)  err "$(bi "не работает" "not working"): ${SHS_WHY}" ;;
    esac
    if [ "$SHS_SCAN" = 1 ]; then w="$(bi "вкл" "on") · $(_shield_nets "$SHS_N")${SHS_DROPS:+ · $(bi "отброшено пакетов" "packets dropped") ${SHS_DROPS}${SHS_SINCE:+ ($(bi "с" "since") ${SHS_SINCE})}}"; else w=$(bi "выкл" "off"); fi
    say "$(bi "Защита (вход)" "Protection (inbound)"): $w"
    if [ "$SHS_VK" = 1 ]; then w="$(bi "вкл" "on")${SHS_REJS:+ · $(bi "отклонено" "rejected") ${SHS_REJS}}"; else w=$(bi "выкл" "off"); fi
    say "$(bi "«ВК: не выпускать»" "“VK: block outbound”"): $w"
    say "$(bi "Исключено" "Excluded"): $(_shield_nets "$SHS_NX") ($(bi "свои" "yours"): ${SHS_NEX}; $(bi "свои добавки" "your additions"): ${SHS_NBL})"
    say "$(bi "Список от" "List from"): ${SHS_DATE:-—} · $(bi "проверено" "checked"): ${SHS_CHECK:-—}"
    [ -n "$SHS_REJ" ] && warn "$(bi "Последний список отклонён:" "The last list was rejected:") ${SHS_REJ}"
    [ -n "$SHS_UPDERR" ] && warn "$(bi "Последнее обновление не скачалось:" "The last update did not download:") ${SHS_UPDERR}"
    if [ -n "$SHS_VKREJ" ]; then
        w="$(bi "Последний список ВК отклонён" "The last VK list was rejected")$(_shield_vkrej_tail): ${SHS_VKREJ}"
        if [ "$SHS_VK" = 1 ]; then warn "$w"; else say "$w"; fi
    fi
    say "$(bi "Журнал" "Log"): ${SHIELD_LOG}"
    case "$SHS_ST" in ok) return 0 ;; bad) return 1 ;; *) return 3 ;; esac
}

# ВК пуст — включать нечего (REVIEW-3 №1): правила без сетей выглядели бы
# рабочими. Причина — последний отказ списка ВК (vkwhy). rc 1 — пуст, сказано.
_shield_vk_empty_refuse() {
    local w
    _shield_vk_empty || return 0
    w=$(_shield_get "$SHIELD_DIR/status" vkwhy) || w=""
    if [ -n "$w" ]; then
        err "$(bi "ВК не включаю: список ВК пуст — последний не прошёл проверку (${w}), а прежнего нет. Включить можно, когда придёт исправный список: goinstall --shield update, затем goinstall --shield vk on." "Not turning VK on: the VK list is empty — the last one failed the check (${w}), and there is no previous one. It can be turned on once a sound list arrives: goinstall --shield update, then goinstall --shield vk on.")"
    else
        err "$(bi "ВК не включаю: список ВК пуст — закрывать нечего." "Not turning VK on: the VK list is empty — nothing to block.")"
    fi
    return 1
}
# Перед «vk on»: принятый ВК против адресов GitHub (REVIEW-3 №2б) — сеть с
# таким адресом отрезала бы сервер от обновлений, и обновление само это не
# вылечит (качает через GitHub). Адреса не разрешились — строка в журнал и
# включаем: проверит такт. rc 1 — отказ, сказано.
_shield_vk_gh_refuse() {
    local rc
    _shield_gh_resolve
    _shield_gh_note || return 0
    _shield_vk_gh "$SHIELD_DIR/lists/vk4" "$SHIELD_DIR/lists/vk6"; rc=$?
    case "$rc" in
        0) return 0 ;;
        7) err "$(bi "ВК не включаю: в списке ВК сеть ${SHIELD_GHNET} с адресом GitHub ${SHIELD_GHADDR} — сервер не дошёл бы до обновлений. Добавьте ${SHIELD_GHADDR} в исключения или дождитесь исправного списка." "Not turning VK on: the VK list has ${SHIELD_GHNET} holding the GitHub address ${SHIELD_GHADDR} — the server could not reach updates. Add ${SHIELD_GHADDR} to the exclusions or wait for a sound list.")"
           shield_log "$(bi "ВК не включён: в списке ВК сеть ${SHIELD_GHNET} с адресом GitHub ${SHIELD_GHADDR}" "VK not turned on: the VK list has ${SHIELD_GHNET} holding the GitHub address ${SHIELD_GHADDR}")" ;;
        *) err "$(bi "ВК не включаю: список ВК не сверить с адресами GitHub (код ${rc})." "Not turning VK on: cannot match the VK list against the GitHub addresses (code ${rc}).")" ;;
    esac
    return 1
}
# goVLESS pro или бесплатный Lite в режиме Reality: Xray набирает домен
# маскировки (REALITY dest) на каждое входящее соединение. Домен в сетях ВК
# (в списке goVLESS для серверов в РФ есть vk.com, ok.ru, dzen.ru) — цепочка
# vk_output отклонит этот набор, и VLESS сервера встанет у всех (REVIEW-5 №1).
# config.json — чужой ввод: читается JSON-разбором, домен — строго имя хоста.
# Печатает домен. rc 0 — Reality, домен прочитан; 1 — goVLESS нет или режим
# не Reality; 2 — Reality, а домен не прочитать.
_shield_mask_domain() {
    local f
    prod_installed govless || return 1
    f=$(prod_config_file govless) || return 1
    [ -f "$f" ] || return 1
    python3 -I - "$f" <<'PY' 2>/dev/null
import json, re, sys
try:
    with open(sys.argv[1], 'rb') as fh:
        raw = fh.read(1048577)
    if len(raw) > 1048576:
        raise ValueError('big')
    c = json.loads(raw.decode('utf-8'))
except Exception:
    sys.exit(2)
if not isinstance(c, dict):
    sys.exit(2)
mode, dom = c.get('mode'), c.get('mask_domain')
# Pro — TLS со своим доменом, маскировки нет. Режим не записан и домена нет —
# goVLESS ещё не настроен.
if mode == 'pro' or (mode != 'lite' and dom in (None, '')):
    sys.exit(1)
if not isinstance(dom, str):
    sys.exit(2)
d = dom.strip().lower().rstrip('.')
if len(d) > 253 or '..' in d or not re.fullmatch(r'[a-z0-9][a-z0-9.-]*\.[a-z]{2,}', d):
    sys.exit(2)
print(d)
PY
}
# Домены ВК — на случай, когда адреса домена не разрешились (нет сети, DNS).
# Сверены 03.11.2026 с сетями списка ВК; boosty.to в них нет — не здесь.
_shield_mask_known() {
    case ".$1" in
        *.vk.com|*.vk.ru|*.vk.me|*.vk.company|*.vkontakte.ru|*.vkvideo.ru|*.userapi.com|*.vk-cdn.net|*.vkuser.net) return 0 ;;
        *.ok.ru|*.odnoklassniki.ru|*.mycdn.me|*.mail.ru|*.dzen.ru|*.max.ru|*.oneme.ru|*.rustore.ru|*.youla.ru|*.vkplay.ru|*.vkplay.live) return 0 ;;
    esac
    return 1
}
# Адреса домена маскировки; в наборе — GOINST_SHIELD_MASK_ADDRS.
_shield_mask_addrs() {
    if [ -n "${GOINST_TEST:-}" ]; then printf '%s\n' ${GOINST_SHIELD_MASK_ADDRS:-}; return 0; fi
    command -v getent >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 0
    timeout 10 getent ahosts "$1" 2>/dev/null | awk '!s[$1]++ { print $1 }'
}
# Домен маскировки goVLESS против принятого ВК — по адресам домена (свои
# исключения пропускают адрес и в цепочках ВК); адреса не разрешились — по
# имени. rc 0 — помехи нет; 7 — домен в ВК (SHIELD_MASK, SHIELD_MASKWHY —
# фраза для человека); 2 — Reality, а домен не прочитан (SHIELD_MASKWHY).
# SHIELD_MASKITEM — первый пункт списка «что не будет работать» (7 и 2).
_shield_mask_vk() {
    local rc
    SHIELD_MASKITEM=""
    _shield_mask_vk_ "$@"; rc=$?
    case "$rc" in
        7) SHIELD_MASKITEM=$(bi "VLESS Reality этого сервера (маскировка под ${SHIELD_MASK}) — у всех клиентов" "This server's VLESS Reality (masquerading as ${SHIELD_MASK}) — for all clients") ;;
        2) SHIELD_MASKITEM=$(bi "VLESS Reality этого сервера — у всех клиентов, если он маскируется под сайт из ВК" "This server's VLESS Reality — for all clients, if it masquerades as a site in VK") ;;
    esac
    return "$rc"
}
_shield_mask_vk_() {
    local rc a n out
    local -a ad=()
    SHIELD_MASKWHY=""
    SHIELD_MASK=$(_shield_mask_domain); rc=$?
    [ "$rc" = 1 ] && { SHIELD_MASK=""; return 0; }
    if [ "$rc" != 0 ] || [ -z "$SHIELD_MASK" ]; then
        SHIELD_MASK=""
        SHIELD_MASKWHY=$(bi "Не прочитать, под какой сайт маскируется VLESS Reality ($(prod_config_file govless))" "Cannot read which site VLESS Reality masquerades as ($(prod_config_file govless))")
        return 2
    fi
    while IFS= read -r a; do
        case "$a" in *[!0-9A-Fa-f:.]*|'') ;; *) ad+=("$a") ;; esac
    done < <(_shield_mask_addrs "$SHIELD_MASK")
    if [ "${#ad[@]}" -gt 0 ]; then
        out=$(_shield_py hits "$SHIELD_DIR/lists/vk4" "$SHIELD_DIR/lists/vk6" "$SHIELD_DIR/exclude" "${ad[@]}" 2>/dev/null); rc=$?
        case "$rc" in
            0) return 0 ;;
            7) read -r _ n a <<<"$out"
               SHIELD_MASKWHY=$(bi "VLESS Reality маскируется под ${SHIELD_MASK}: адрес ${a} — в сети ВК ${n}" "VLESS Reality masquerades as ${SHIELD_MASK}: address ${a} is in the VK network ${n}")
               return 7 ;;
        esac
    fi
    _shield_mask_known "$SHIELD_MASK" || return 0
    SHIELD_MASKWHY=$(bi "VLESS Reality маскируется под ${SHIELD_MASK}: это домен ВК" "VLESS Reality masquerades as ${SHIELD_MASK}: a VK domain")
    return 7
}
# Перед «vk on»: домен маскировки в ВК — отказ словами; не прочитан —
# включаем (просит человек), но предупреждаем. rc 1 — отказ, сказано.
_shield_mask_refuse() {
    _shield_mask_vk
    case "$?" in
        7) err "$(bi "ВК не включаю: ${SHIELD_MASKWHY}. С закрытым ВК VLESS этого сервера перестал бы работать. Смените домен маскировки (команда govless) на сайт вне ВК." "Not turning VK on: ${SHIELD_MASKWHY}. With VK closed, this server's VLESS would stop working. Change the masking domain (the govless command) to a site outside VK.")"
           shield_log "$(bi "ВК не включён: домен маскировки VLESS Reality ${SHIELD_MASK} — в ВК" "VK not turned on: the VLESS Reality masking domain ${SHIELD_MASK} is in VK")"
           return 1 ;;
        2) warn "$(bi "${SHIELD_MASKWHY}. Если это сайт из сетей ВК, VLESS перестанет работать. Выключить: goinstall --shield vk off." "${SHIELD_MASKWHY}. If it is a site in VK networks, VLESS will stop working. To turn it off: goinstall --shield vk off.")" ;;
    esac
    return 0
}
# Узел РФ goKaskad pro: ВК закрыт и для клиентов каскада (решение владельца
# 03.11.2026 — без исключения, одной строкой при включении).
_shield_kaskad_note() {
    prod_installed gokaskad || return 0
    say "$(bi "$(prod_name gokaskad): ВК закрыт и для клиентов каскада — у них всё это тоже не откроется." "$(prod_name gokaskad): VK is closed to the cascade clients too — none of this will open for them either.")"
}
# Что не будет работать при закрытом ВК — списком, по строке на пункт
# (решение владельца 03.11.2026). _shield_vk_say <on|ask> [первый пункт]:
# on — ВК включён (в конце goKaskad pro и как выключить), ask — перед
# вопросом меню. Первый пункт — VLESS Reality с маскировкой под ВК.
_shield_vk_say() {
    local i
    if [ "$1" = ask ]; then
        say "$(bi "Соединения к сетям ВК будут отклоняться — через VPN и с самого сервера не будут работать:" "Connections to VK networks will be rejected — these will not work over the VPN or from the server itself:")"
    else
        say "$(bi "Сети ВК закрыты — через VPN и с самого сервера не будут работать:" "VK networks are closed — these will not work over the VPN or from the server itself:")"
    fi
    [ -n "${2:-}" ] && printf '     • %s\n' "$2" >&2
    while IFS= read -r i; do printf '     • %s\n' "$i" >&2; done <<<"$(bi "$SHIELD_VK_SVC_RU" "$SHIELD_VK_SVC_EN")"
    [ "$1" = ask ] || _shield_vk_after
}
_shield_vk_after() {
    _shield_kaskad_note
    say "$(bi "Выключить ВК: goinstall --shield vk off или пункт 2 в меню «Защита от сканеров»." "To turn VK off: goinstall --shield vk off or item 2 in the “Scanner protection” menu.")"
}
# Включить/выключить часть: scan|vk 0|1. Выключено всё — таблица остаётся
# ради счёта статистики (1.2.4); без счёта (stl=0) — снимается.
shield_toggle() {  # shield_toggle <scan|vk> <0|1>
    local scan vk
    shield_installed || return 3
    _shield_lock_say || return 1
    scan=$(_shield_get "$SHIELD_DIR/settings" scan) || scan=0
    vk=$(_shield_get "$SHIELD_DIR/settings" vk) || vk=0
    if [ "$1:$2" = vk:1 ]; then
        # Уже включён — менять нечего; находку такта (ghhit) не трогаем.
        [ "$vk" = 1 ] && { _shield_unlock; ok "$(bi "«ВК: не выпускать» уже включено." "“VK: block outbound” is already on.")"; return 0; }
        { _shield_vk_empty_refuse && _shield_vk_gh_refuse && _shield_mask_refuse; } || { _shield_unlock; return 1; }
    fi
    if [ "$1" = scan ]; then scan="$2"; else vk="$2"; fi
    printf 'scan=%s\nvk=%s\n' "$scan" "$vk" > "$SHIELD_DIR/settings"; chmod 600 "$SHIELD_DIR/settings"
    if ! shield_apply; then
        err "$(bi "Не применилось: ${SHIELD_ERR}" "Did not apply: ${SHIELD_ERR}")"
        shield_log "$(bi "переключение $1=$2 не применилось: ${SHIELD_ERR}" "switching $1=$2 did not apply: ${SHIELD_ERR}")"
        _shield_unlock; return 1
    fi
    shield_log "$(bi "настройки: сканеры ${scan}, ВК ${vk}" "settings: scanners ${scan}, VK ${vk}")"
    # Находка такта про GitHub в ВК (ghhit) относится к включённому ВК: «vk
    # on» только что сверил сам, «vk off» её снимает.
    _shield_set "$SHIELD_DIR/status" "check=$(_shield_now)" "result=ok" "why="
    [ "$1" = vk ] && _shield_set "$SHIELD_DIR/status" "ghhit="
    _shield_unlock
    case "$1:$2" in
        scan:1) ok "$(bi "Защита (вход): включена." "Protection (inbound): on.")" ;;
        scan:0) # «Только считает» — если счёт поднялся (stl ≥ 1), иначе неправда.
                if [ "$(_shield_num "$SHIELD_DIR/status" stl)" -ge 1 ]; then
                    ok "$(bi "Защита (вход): выключена — сервер не блокирует, только считает." "Protection (inbound): off — the server does not block, only counts.")"
                else
                    ok "$(bi "Защита (вход): выключена — сервер не блокирует." "Protection (inbound): off — the server does not block.")"
                fi
                # ВК по умолчанию включён (1.2.2): «off» его не трогает — сказать.
                [ "$vk" = 1 ] && say "$(bi "«ВК: не выпускать» остаётся включённым. Выключить: goinstall --shield vk off или пункт 2 в меню «Защита от сканеров»." "“VK: block outbound” stays on. To turn it off: goinstall --shield vk off or item 2 in the “Scanner protection” menu.")" ;;
        vk:1)   ok "$(bi "«ВК: не выпускать»: включено." "“VK: block outbound”: on.")"
                # Список — тот, что сверил _shield_mask_refuse выше; из меню он
                # уже показан до вопроса (SHIELD_VKLISTED).
                if [ -n "${SHIELD_VKLISTED:-}" ]; then _shield_vk_after; else _shield_vk_say on "${SHIELD_MASKITEM:-}"; fi ;;
        vk:0)   ok "$(bi "«ВК: не выпускать»: выключено." "“VK: block outbound”: off.")" ;;
    esac
    return 0
}

# Удалить защиту: правила, юниты, файлы. Отказ записывается — само больше
# не предложит; меню даёт включить снова.
shield_remove() {
    _shield_paths
    _shield_lock_say || return 1
    # Последний час счёта — в статистику до снятия таблицы; сама статистика
    # остаётся (stats/), стирает её --shield stats reset.
    shield_stats_snap
    shield_teardown || warn "$(bi "Таблицу ${SHIELD_TABLE} снять не вышло." "Could not remove the ${SHIELD_TABLE} table.")"
    case "$SHIELD_DIR" in
        /*/*) find "$SHIELD_DIR" -mindepth 1 -maxdepth 1 ! -name .lock ! -name stats -exec rm -rf {} + 2>/dev/null ;;
    esac
    printf 'removed\n' > "$SHIELD_DIR/declined" 2>/dev/null; chmod 600 "$SHIELD_DIR/declined" 2>/dev/null
    _shield_unlock
    ok "$(bi "Защита от сканеров удалена: таблица, таймер и списки сняты." "Scanner protection is removed: the table, the timer and the lists are gone.")"
    if _shield_has_stats; then
        say "$(bi "Статистика осталась: ${SHIELD_STATS}. Удалить: goinstall --shield stats reset" "The statistics stay: ${SHIELD_STATS}. To delete: goinstall --shield stats reset")"
    fi
    return 0
}

# Свои исключения и добавки: ввод проверяется так же строго, как список.
shield_list_add() {  # shield_list_add <exclude|block> <адрес/сеть>
    local kind="$1" v out rc f n
    _shield_paths; f="$SHIELD_DIR/$kind"
    shield_addrs > "$SHIELD_DIR/addrs" 2>/dev/null
    if [ "$kind" = block ]; then out=$(_shield_py addr block "$2" "$SHIELD_DIR/addrs" 2>/dev/null); rc=$?
    else out=$(_shield_py addr allow "$2" "$SHIELD_DIR/addrs" 2>/dev/null); rc=$?; fi
    case "$rc" in
        0) ;;
        5) [ "$kind" = exclude ] && { SHIELD_ERR=$(bi "частная или служебная сеть — её и так не блокируем, исключать незачем" "a private or special network — it is never blocked anyway, nothing to exclude"); return 1; }
           SHIELD_ERR=$(bi "частная или служебная сеть — её и так не блокируем" "a private or special network — it is never blocked anyway"); return 1 ;;
        3) SHIELD_ERR=$(bi "слишком широкая сеть: не шире /8 для IPv4 и /16 для IPv6" "too wide a network: no wider than /8 for IPv4 and /16 for IPv6"); return 1 ;;
        6) SHIELD_ERR=$(bi "в этой сети адрес самого сервера (${out#own })" "this network holds the server's own address (${out#own })"); return 1 ;;
        127) SHIELD_ERR=$(bi "нет python3" "python3 is missing"); return 1 ;;
        *) SHIELD_ERR=$(bi "не адрес и не сеть: нужно вида 203.0.113.7 или 203.0.113.0/24 (без лишних битов)" "not an address or network: use 203.0.113.7 or 203.0.113.0/24 (no host bits)"); return 1 ;;
    esac
    v="${out%%$'\n'*}"
    if grep -qxF "$v" "$f" 2>/dev/null; then SHIELD_ERR=$(bi "уже в списке" "already listed"); return 1; fi
    # grep -c на пустом файле печатает «0» и выходит с 1: «|| echo 0» дал бы
    # «0\n0», и [ упал бы — «уже 1000 строк» после удаления последней.
    n=$(grep -c . "$f" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -lt 1000 ] || { SHIELD_ERR=$(bi "в списке уже 1000 строк" "the list already has 1000 lines"); return 1; }
    printf '%s\n' "$v" >> "$f"; chmod 600 "$f"
    SHIELD_ADDED="$v"
    return 0
}
shield_list_del() {  # shield_list_del <exclude|block> <номер строки>
    local f n="$2" c
    _shield_paths; f="$SHIELD_DIR/$1"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    c=$(grep -c . "$f" 2>/dev/null); case "$c" in ''|*[!0-9]*) c=0 ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "$c" ] || return 1
    SHIELD_ADDED=$(sed -n "${n}p" "$f")
    sed "${n}d" "$f" > "$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# Предложение — один раз, сразу после выбора языка, до ключа и продуктов.
# Не спрашиваем: без терминала, когда уже стоит, когда отказались или сервер
# не поддерживает (файл declined), во время обновления Ubuntu, без сети.
shield_offer() {
    _shield_paths
    osup_busy && return 0
    if [ -n "${GOINST_TEST:-}" ] && [ -z "${GOINST_SHIELD_TEST:-}" ]; then return 0; fi
    # Стоит — только привести копию для таймера и юниты к этой версии.
    if shield_installed; then shield_sync; return 0; fi
    [ -n "${GOINST_NO_NET:-}" ] && return 0
    [ -e "$SHIELD_DIR/declined" ] && return 0
    [ -t 0 ] || [ "${GOINST_SHIELD_TTY:-}" = 1 ] || return 0
    shield_runner_src >/dev/null || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    SHIELD_SAID=1
    print_header "$(bi "Защита от сканеров и ботов" "Scanner and bot protection")"
    if ! shield_support; then
        warn "$(bi "Здесь её не поставить: ${SHIELD_ERR}." "It cannot be set up here: ${SHIELD_ERR}.")"
        _shield_unsupported "$SHIELD_ERR"; return 0
    fi
    say "$(bi "Сети госорганов и ВК, из которых сканируют серверы, не увидят ваших портов: новые соединения из них отбрасываются." "Government and VK networks that scan servers will not see your ports: new connections from them are dropped.")"
    say "$(bi "Ещё закрывает сети ВК для клиентов VPN и самого сервера, чтобы ВК не засветил его адрес: не откроются ВКонтакте и VK Видео, Одноклассники, Mail.ru, Макс, Дзен, RuStore, Юла, VK Play, VK Cloud и другие сервисы VK." "It also closes VK networks to VPN clients and the server itself, so VK cannot expose its address: VKontakte and VK Video, Odnoklassniki, Mail.ru, Max, Dzen, RuStore, Youla, VK Play, VK Cloud and other VK services will not open.")"
    say "$(bi "Списки — из открытого проекта AS_Network_List, обновляются каждый день. SSH открыт всегда. Выключить — в меню." "The lists come from the open AS_Network_List project and update daily. SSH always stays open. Turn it off in the menu.")"
    _shield_have_nft || say "$(bi "Для этого поставлю пакет nftables." "For this I will install the nftables package.")"
    # Умолчание «Да» — решение владельца; поэтому Enter, нажатый заранее
    # (отсчёт сводки, вопрос о MTU), не должен стать ответом.
    [ -t 0 ] && ui_flush_input
    if ! confirm "$(bi "Включить защиту от сканеров?" "Turn on scanner protection?")" y; then
        mkdir -p "$SHIELD_DIR" 2>/dev/null && chmod 700 "$SHIELD_DIR" 2>/dev/null
        printf 'declined\n' > "$SHIELD_DIR/declined" 2>/dev/null; chmod 600 "$SHIELD_DIR/declined" 2>/dev/null
        say "$(bi "Не включаю. Включить потом: меню → «Защита от сканеров» или goinstall --shield on" "Not turning it on. Later: menu → “Scanner protection” or goinstall --shield on")"
        return 0
    fi
    shield_install
    return 0
}

# После установщика продукта: он мог сбросить правила (flush ruleset у
# себя) — та же проверка, что у таймера.
# Защита ставится до продуктов (сразу после языка), и ВК по умолчанию уже
# включён, когда ставят goVLESS или goKaskad pro: здесь — сказать, что это
# значит для них (REVIEW-5 №1, решение владельца 03.11.2026). Выбор ВК не
# меняется: выключает человек.
shield_postcheck() {  # shield_postcheck [id продукта]
    shield_installed || return 0
    _shield_enabled || return 0
    if _shield_lock 30; then shield_check >/dev/null; _shield_unlock; fi
    [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ] || return 0
    case "${1:-}" in
        govless)
            _shield_mask_vk
            case "$?" in
                7) warn "$(bi "${SHIELD_MASKWHY}. «ВК: не выпускать» включено — VLESS этого сервера не будет работать." "${SHIELD_MASKWHY}. “VK: block outbound” is on — this server's VLESS will not work.")"
                   _shield_vk_say on "$SHIELD_MASKITEM"
                   say "$(bi "Или смените домен маскировки (команда govless) на сайт вне ВК." "Or change the masking domain (the govless command) to a site outside VK.")" ;;
                2) warn "$(bi "${SHIELD_MASKWHY}. «ВК: не выпускать» включено — если это сайт из сетей ВК, VLESS не будет работать." "${SHIELD_MASKWHY}. “VK: block outbound” is on — if it is a site in VK networks, VLESS will not work.")"
                   _shield_vk_say on "$SHIELD_MASKITEM" ;;
            esac ;;
        gokaskad) _shield_vk_say on ;;
    esac
    return 0
}

# goinstall --shield … Коды: 0 — работает, 1 — не работает (или не вышло),
# 3 — не стоит (или выключена), 64 — неверная команда.
shield_cli() {
    local a="${1:-status}" b="${2:-}" yes="" x rc
    for x in "$@"; do case "$x" in --yes|-y) yes=1 ;; esac; done
    _shield_paths
    case "$a" in tick|remove|stats) ;; *) shield_sync ;; esac
    case "$a" in
        status) shield_status_print; return $? ;;
        check)  shield_installed || { say "$(bi "Защита от сканеров не стоит." "Scanner protection is not installed.")"; return 3; }
                _shield_lock_say || return 1
                shield_check; rc=$?; _shield_unlock
                if [ "$rc" -eq 0 ]; then
                    _shield_enabled || { say "$(bi "Защита выключена." "The protection is off.")"; return 3; }
                    # Сканеры выключены, ВК включён (после «off» на новой установке, 1.2.2).
                    if [ "$(_shield_get "$SHIELD_DIR/settings" scan)" = 1 ]; then ok "$(bi "Защита от сканеров работает." "Scanner protection is working.")"
                    else ok "$(bi "«ВК: не выпускать» работает (защита входа выключена)." "“VK: block outbound” is working (inbound protection is off).")"; fi
                fi
                return "$rc" ;;
        update) shield_installed || { say "$(bi "Защита от сканеров не стоит." "Scanner protection is not installed.")"; return 3; }
                _shield_lock_say || return 1
                shield_update; rc=$?; _shield_unlock
                return "$rc" ;;
        tick)   shield_tick; return 0 ;;
        stats)  shift; shield_stats_cli "$@"; return $? ;;
        on)     if shield_installed; then shield_toggle scan 1; return $?; fi
                osup_busy_refuse && return 1
                shield_install; rc=$?; [ "$rc" -eq 0 ] || return 1; return 0 ;;
        off|remove)
                shield_installed || { say "$(bi "Защита от сканеров не стоит." "Scanner protection is not installed.")"; return 3; }
                if [ -z "$yes" ]; then
                    if [ ! -t 0 ]; then err "$(bi "Без терминала спросить некого: goinstall --shield ${a} --yes" "No terminal to ask: goinstall --shield ${a} --yes")"; return 64; fi
                    if [ "$a" = off ]; then confirm "$(bi "Выключить защиту от сканеров и ботов?" "Turn off the scanner and bot protection?")" n || { say "$(bi "Оставил как есть." "Left as is.")"; return 0; }
                    else confirm "$(bi "Удалить защиту от сканеров: правила, таймер, списки?" "Remove scanner protection: the rules, the timer, the lists?")" n || { say "$(bi "Оставил как есть." "Left as is.")"; return 0; }; fi
                fi
                if [ "$a" = off ]; then shield_toggle scan 0; else shield_remove; fi
                return $? ;;
        vk)     shield_installed || { say "$(bi "Защита от сканеров не стоит. Сначала: goinstall --shield on" "Scanner protection is not installed. First: goinstall --shield on")"; return 3; }
                case "$b" in
                    on)  shield_toggle vk 1; return $? ;;
                    off) shield_toggle vk 0; return $? ;;
                    *)   usage; return 64 ;;
                esac ;;
        *) usage; return 64 ;;
    esac
}

# ── нумерованное меню «Защита от сканеров» ─────────────────────────────
menu_items_shield() {
    local l i
    MENU_REFRESH_SEC=0; MENU_REFRESH_HOOK=""; MENU_FOOTER_INFO=""
    MENU_TITLE="$(bi "Защита от сканеров" "Scanner protection")"
    MENU_SUB="$(bi "сети госорганов и ВК не видят портов сервера" "government and VK networks do not see the server's ports")"
    MENU_ITEMS=(); MENU_W_STATUS=8; MENU_W_EXTRA=0
    shield_state --live
    if [ "$SHS_ST" = none ]; then
        _comp_menu_note "$(bi "Новые соединения из сетей, которые сканируют серверы, отбрасываются. Ещё закрывает сети ВК для клиентов VPN и самого сервера. Списки — AS_Network_List, обновляются каждый день. SSH открыт всегда." "New connections from networks that scan servers are dropped. It also closes VK networks to VPN clients and the server itself. Lists: AS_Network_List, updated daily. SSH always stays open.")"
        [ -n "$SHS_UNSUP" ] && _comp_menu_note "✗ $(bi "раньше не поставилась:" "did not install earlier:") ${SHS_UNSUP}" r
        MENU_ITEMS+=("-|||")
        MENU_ITEMS+=("1|$(bi "Включить защиту" "Turn protection on")|||$(bi "скачать списки и применить" "download the lists and apply")")
        MENU_ITEMS+=("0|$(bi "Назад" "Back")|||")
        menu_fit_widths 12; return 0
    fi
    case "$SHS_ST" in
        ok)  _comp_menu_note "✓ ${SHS_TEXT}" g ;;
        bad) _comp_menu_note "✗ $(bi "не работает" "not working"): ${SHS_WHY}" r ;;
        *)   _comp_menu_note "$(bi "выключена: и сканеры, и ВК" "off: both scanners and VK")" ;;
    esac
    _comp_menu_note "$(bi "Исключено" "Excluded"): $(_shield_nets "$SHS_NX") · $(bi "список от" "list from") ${SHS_DATE:-—} · $(bi "проверено" "checked") ${SHS_CHECK:-—}"
    [ -n "$SHS_DROPS" ] && _comp_menu_note "$(bi "Отброшено пакетов" "Packets dropped"): ${SHS_DROPS}${SHS_SINCE:+ ($(bi "с" "since") ${SHS_SINCE})}"
    [ -n "$SHS_REJ" ] && _comp_menu_note "! $(bi "последний список отклонён:" "the last list was rejected:") ${SHS_REJ}" y
    [ -n "$SHS_UPDERR" ] && _comp_menu_note "! $(bi "последнее обновление не скачалось:" "the last update did not download:") ${SHS_UPDERR}" y
    if [ -n "$SHS_VKREJ" ]; then
        l=y; [ "$SHS_VK" = 1 ] || l=""   # без цвета — серым
        _comp_menu_note "! $(bi "список ВК отклонён" "the VK list was rejected")$(_shield_vkrej_tail): ${SHS_VKREJ}" "$l"
    fi
    MENU_ITEMS+=("-|||")
    # Пункты — те же, что в меню «Защита» «Аркады» (shield_items).
    shield_items
    for ((i = 0; i < ${#SHI_KEY[@]}; i++)); do
        if [ "${SHI_KEY[i]}" = 0 ]; then MENU_ITEMS+=("0|${SHI_LABEL[i]}|||"); continue; fi
        case "${SHI_TAGT[i]}" in ok) l="g:" ;; warn) l="y:" ;; *) l="d:" ;; esac
        MENU_ITEMS+=("${SHI_KEY[i]}|${SHI_LABEL[i]}|$l${SHI_TAG[i]}||${SHI_HINT[i]}")
    done
    menu_fit_widths 12
}
_shield_pause() { echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") " >&2; read -r || true; }
# Действия пунктов — общие для нумерованного меню и «Аркады» (там — в
# обычном терминале): вопросы «1) Да / 2) Нет» и итог словами.
shield_do_on() { osup_busy_refuse || shield_install; }
shield_do_scan() {
    if [ "$(_shield_get "$SHIELD_DIR/settings" scan)" = 1 ]; then
        confirm "$(bi "Выключить защиту от сканеров и ботов? Порты сервера снова будут видны сетям из списка." "Turn off the scanner and bot protection? The server's ports become visible to the listed networks again.")" n && shield_toggle scan 0
    else shield_toggle scan 1; fi
}
shield_do_vk() {
    if [ "$(_shield_get "$SHIELD_DIR/settings" vk)" = 1 ]; then shield_toggle vk 0; return $?; fi
    # Пустой ВК — сразу отказ, без вопроса (его повторит и shield_toggle).
    _shield_vk_empty_refuse || return 1
    # Маскировка VLESS Reality под сайт из ВК — тоже до вопроса (REVIEW-5 №1).
    _shield_mask_vk
    if [ "$?" = 7 ]; then _shield_mask_refuse; return 1; fi
    _shield_vk_say ask "${SHIELD_MASKITEM:-}"
    confirm "$(bi "Включить «ВК: не выпускать»?" "Turn on “VK: block outbound”?")" n && SHIELD_VKLISTED=1 shield_toggle vk 1
}
shield_do_update() { _shield_lock_say || return 1; shield_update; local rc=$?; _shield_unlock; return "$rc"; }
shield_do_remove() {
    confirm "$(bi "Удалить защиту от сканеров: правила, таймер, списки?" "Remove scanner protection: the rules, the timer, the lists?")" n && shield_remove
}
shield_menu() {
    while true; do
        menu_items_shield
        pick_menu || return 0
        case "$SHS_ST:$PICK_KEY" in
            *:0) return 0 ;;
            none:1) shield_do_on; _shield_pause ;;
            none:*) ;;
            *:1) shield_do_scan; _shield_pause ;;
            *:2) shield_do_vk; _shield_pause ;;
            *:3) shield_do_update; _shield_pause ;;
            *:4) shield_list_menu exclude ;;
            *:5) shield_list_menu block ;;
            *:6) shield_stats_cli; _shield_pause ;;
            *:7) shield_stats_cli top; _shield_pause ;;
            *:8) shield_stats_cli size; shield_stats_cli reset; _shield_pause ;;
            *:9) shield_do_remove; _shield_pause; shield_installed || return 0 ;;
        esac
    done
}
# Список исключений или добавок: добавить (ввод), убрать (по номеру).
shield_list_menu() {  # shield_list_menu <exclude|block>
    local kind="$1" a i l
    local -a rows=()
    _shield_paths
    while true; do
        rows=()
        [ -s "$SHIELD_DIR/$kind" ] && mapfile -t rows < <(grep . "$SHIELD_DIR/$kind")
        if [ "$kind" = exclude ]; then print_header "$(bi "Исключения — эти адреса не блокируются никогда" "Exclusions — these addresses are never blocked")"
        else print_header "$(bi "Свои добавки — блокировать вместе со списком" "Your additions — blocked along with the list")"; fi
        if [ "${#rows[@]}" -eq 0 ]; then say "$(bi "Пусто." "Empty.")"
        else for ((i = 0; i < ${#rows[@]}; i++)); do echo -e "  ${CYAN}$(( i + 1 )))${NC} ${rows[$i]}" >&2; done; fi
        echo "" >&2
        echo -e "  ${CYAN}+)${NC} $(bi "добавить" "add")    ${CYAN}-)${NC} $(bi "убрать по номеру" "remove by number")    ${CYAN}0)${NC} $(bi "назад" "back")" >&2
        read_line a || return 0
        case "$a" in
            0|'') return 0 ;;
            +) read_line l "  $(bi "Адрес или сеть (203.0.113.7, 203.0.113.0/24, 2001:db8::/48)" "Address or network (203.0.113.7, 203.0.113.0/24, 2001:db8::/48)"): " || continue
               l="${l//[[:space:]]/}"; [ -n "$l" ] || continue
               _shield_lock_say || continue
               if shield_list_add "$kind" "$l"; then
                   if shield_apply; then ok "$(bi "Добавлено:" "Added:") ${SHIELD_ADDED}"
                   else err "$(bi "Добавлено, но не применилось:" "Added, but did not apply:") ${SHIELD_ERR}"; fi
               else err "$(bi "Не добавлено:" "Not added:") ${SHIELD_ERR}"; fi
               _shield_unlock ;;
            -) read_line l "  $(bi "Номер" "Number"): " || continue
               _shield_lock_say || continue
               if shield_list_del "$kind" "$l"; then
                   if shield_apply; then ok "$(bi "Убрано:" "Removed:") ${SHIELD_ADDED}"
                   else err "$(bi "Убрано, но не применилось:" "Removed, but did not apply:") ${SHIELD_ERR}"; fi
               else warn "$(bi "Нет такого номера." "No such number.")"; fi
               _shield_unlock ;;
            *) warn "$(bi "Ответьте: + , - или 0." "Answer +, - or 0.")" ;;
        esac
    done
}

# ── обновление Ubuntu до 24.04 ──────────────────────────────────────────
# Решение заказчика 14.10: кнопка «o» обновляет Ubuntu 20.04 и 22.04 до 24.04
# LTS. С 20.04 — два прыжка (20.04 → 22.04 → 24.04), после перезагрузок
# обновление продолжается само. Только Ubuntu, на 24.04 и новее пункта нет:
# штатная программа там уже предлагает 26.04. Третье исключение из «ничего
# не настраивает» (после MTU и «Компонентов») — только по выбору человека,
# после предупреждения о бэкапе и подтверждения цифрой.
#
# Опыт на серверах (14.10): do-release-upgrade -f DistUpgradeViewNonInteractive
# из службы systemd без tty проходит без вопросов и сам не перезагружает;
# сторонние списки уходят в *.list.distUpgrade с прежним кодовым именем;
# авто-пакеты nginx-core и libnginx-mod-stream апгрейдер сносит как ненужные —
# nginx не стартует («unknown directive stream»); ufw удаляется на прыжке в
# 24.04 (несовместим с iptables-persistent); venv ботов ломается. Поэтому:
# служба шаг за запуском, apt-mark manual до, сверка и починка после.
#
# Исполнитель — служба goinstall-os-upgrade, она зовёт КОПИЮ скрипта
# (os-upgrade/runner.sh): самообновление пишет goinstall на месте, а bash
# читает скрипт по ходу. Состояние — os-upgrade/state (key=value), журнал —
# os-upgrade/log, снимок «до» — os-upgrade/before/.
GOINST_SELF_PATH="${BASH_SOURCE[0]:-$0}"
OSUP_TARGET="24.04"
OSUP_UNIT="goinstall-os-upgrade.service"
# Списки продуктов, которые goInstaller возвращает на 24.04. Возврат правит
# файлы продуктов — это входит в согласие на кнопку; выключается одним флагом
# (GOINST_OSUP_FIX_LISTS=0), тогда только замечание.
OSUP_LISTS="godns-dnsdist.list cloudflare-client.list cloudflared.list"
OSUP_FIX_LISTS="${GOINST_OSUP_FIX_LISTS:-1}"
declare -A OSU=()
OSU_NOTES=(); OSU_DID=(); OSUP_CHK=(); OSUP_BAD=0; OSUP_PLAN=(); OSUP_ERR=""

_osup_paths() {
    local r="${GOINST_FS_ROOT:-}"
    OSUP_DIR="${GOINST_DIR}/os-upgrade"; OSUP_STATE="$OSUP_DIR/state"; OSUP_LOG="$OSUP_DIR/log"
    OSUP_BEFORE="$OSUP_DIR/before"; OSUP_RUNNER="$OSUP_DIR/runner.sh"
    OSUP_APTCONF="$r/etc/apt/apt.conf.d/99goinstall-os-upgrade"
    OSUP_RU="$r/etc/update-manager/release-upgrades"
    OSUP_SL="$r/etc/apt/sources.list.d"
    OSUP_UNITF="${GOINST_SYSTEMD_DIR:-$r/etc/systemd/system}/$OSUP_UNIT"
    OSUP_HOOK="${GOINST_OSUP_HOOK:-$r/etc/profile.d/goinstall-osupgrade.sh}"
}
_osup_now() { printf '%(%s)T' -1; }
osup_log() { _osup_paths; mkdir -p "$OSUP_DIR" 2>/dev/null; printf '[%(%F %T)T] %s\n' -1 "$*" >> "$OSUP_LOG" 2>/dev/null; return 0; }

# Состояние: OSU[ключ], заметки итога OSU_NOTES («имя|что|коротко|шаг|sev»,
# как UD_PROB) и сделанное OSU_DID. Время шагов — «t:<метка>=начало конец»,
# попытки прыжка — «n:rel-<выпуск>».
osup_load() {  # rc 1 — состояния нет
    local l k
    _osup_paths
    OSU=(); OSU_NOTES=(); OSU_DID=()
    [ -r "$OSUP_STATE" ] || return 1
    while IFS= read -r l || [ -n "$l" ]; do
        k="${l%%=*}"
        case "$k" in
            note) OSU_NOTES+=("${l#*=}") ;;
            did) OSU_DID+=("${l#*=}") ;;
            ''|"$l") ;;
            *) OSU[$k]="${l#*=}" ;;
        esac
    done < "$OSUP_STATE"
    # Числа — только цифрами: значения идут в арифметику, битое уронило бы
    # исполнитель под set -u.
    for k in reboots attempt started finished seen kick; do
        case "${OSU[$k]:-}" in ''|*[!0-9]*) [ -n "${OSU[$k]:-}" ] && OSU[$k]=0 ;; esac
    done
    for k in "${!OSU[@]}"; do
        case "$k" in
            n:*) case "${OSU[$k]}" in ''|*[!0-9]*) OSU[$k]=0 ;; esac ;;
            t:*) [[ "${OSU[$k]}" =~ ^[0-9]+( [0-9]+)?$ ]] || unset "OSU[$k]" ;;
        esac
    done
    # «Идёт» без живого исполнителя — прервано: службу сняли вручную, enable
    # не прошёл, исполнитель упал. Иначе запреты висели бы вечно. Сам
    # исполнитель (OSUP_IN_RUNNER) видит состояние как есть.
    if [ "${OSU[status]:-}" = running ] && [ -z "${OSUP_IN_RUNNER:-}" ] && ! osup_alive; then
        OSU[status]=failed; OSU[stale]=1
        if [ "$OSUP_DEAD" = crashed ]; then
            OSU[msg]=$(bi "исполнитель обновления упал — журнал ${OSUP_LOG}, journalctl -u ${OSUP_UNIT}" "the upgrade runner crashed — log ${OSUP_LOG}, journalctl -u ${OSUP_UNIT}")
        else
            OSU[msg]=$(bi "служба обновления не работает (${OSUP_UNIT}) — ход остановился" "the upgrade unit is not working (${OSUP_UNIT}) — the progress stopped")
        fi
    fi
    return 0
}
osup_num() { local v="${OSU[$1]:-0}"; case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$((10#$v))" ;; esac; }
# Исполнитель жив: служба работает сейчас, или жив процесс исполнителя
# (run.pid), или служба включена и ждёт запуска — после загрузки до
# network-online или сразу после osup_start (у неё стоит задание systemd),
# или osup_start только что (OSUP_KICK_TTL с) записал «идёт» и службу ещё
# не запустил: иначе сторонний наблюдатель в этом окне видел бы «упал».
# Задание и свежая отметка проверяются РАНЬШЕ failed: «Попробовать снова»
# ставит задание, а служба остаётся failed, пока оно не начнёт исполняться.
# Включённая, но упавшая служба (failed) — не жив: исполнитель
# упал в этой загрузке (штатно с ошибкой он выходит только через osup_fail,
# который службу снимает), и без этой проверки «идёт» висело бы до
# перезагрузки, а dismiss отказывал бы. OSUP_DEAD: crashed — служба упала,
# gone — службы нет или она стоит без задания.
# Замок run.lock не пробуем: проба flock -n в тот же миг заставила бы
# стартующий исполнитель решить «уже работает» и выйти. run.pid пишется
# сразу за замком.
OSUP_DEAD=""
OSUP_KICK_TTL=60
osup_alive() {
    local st j k d en=0
    _osup_paths
    OSUP_DEAD=""
    # Служба oneshot, пока работает, — «activating», а не «active».
    st=$(systemctl is-active "$OSUP_UNIT" 2>/dev/null) && return 0
    case "$st" in activating|reloading|deactivating) return 0 ;; esac
    osup_runner_pid >/dev/null && return 0
    if [ -f "$OSUP_UNITF" ] && systemctl is-enabled --quiet "$OSUP_UNIT" >/dev/null 2>&1; then
        # Ждёт запуска — у неё задание systemd (номер).
        j=$(systemctl show -p Job --value "$OSUP_UNIT" 2>/dev/null) || j=""
        case "$j" in ''|0) en=1 ;; *) return 0 ;; esac
    fi
    k=$(grep -m1 '^kick=' "$OSUP_STATE" 2>/dev/null) || k=""; k="${k#kick=}"
    case "$k" in ''|*[!0-9]*) ;; *) d=$(( $(_osup_now) - 10#$k )); [ "$d" -ge 0 ] && [ "$d" -lt "$OSUP_KICK_TTL" ] && return 0 ;; esac
    # Упала, или включена, не работает и без задания — исполнитель вышел,
    # не сняв службу: так выходит только упавший.
    if [ "$st" = failed ] || [ "$en" = 1 ]; then OSUP_DEAD=crashed; return 1; fi
    OSUP_DEAD=gone
    return 1
}
# Живой исполнитель по run.pid → печатает pid; rc 1 — нет.
osup_runner_pid() {
    local pid c
    pid=$(cat "$OSUP_DIR/run.pid" 2>/dev/null) || pid=""
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    # После перезагрузки номер мог достаться чужому процессу.
    if [ -r "/proc/$pid/cmdline" ]; then
        c=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || c=""
        case "$c" in *--os-upgrade-run*|*osup_run*) ;; *) return 1 ;; esac
    fi
    printf '%s' "$pid"
}
osup_save() {
    local k n tmp
    _osup_paths
    mkdir -p "$OSUP_DIR" 2>/dev/null; chmod 700 "$OSUP_DIR" 2>/dev/null
    tmp="$OSUP_STATE.tmp"
    {
        for k in status from to target started finished reboots attempt step msg seen kick; do printf '%s=%s\n' "$k" "${OSU[$k]:-}"; done
        for k in "${!OSU[@]}"; do case "$k" in t:*|n:*) printf '%s=%s\n' "$k" "${OSU[$k]}" ;; esac; done
        for n in ${OSU_DID[@]+"${OSU_DID[@]}"}; do printf 'did=%s\n' "$n"; done
        for n in ${OSU_NOTES[@]+"${OSU_NOTES[@]}"}; do printf 'note=%s\n' "$n"; done
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$OSUP_STATE"
}
osup_set() { local v="${2//$'\n'/ }"; OSU[$1]="${v//$'\r'/}"; }
osup_note() { OSU_NOTES+=("${1//$'\n'/ }"); }    # «имя|что|коротко|шаг|sev»
osup_did() { OSU_DID+=("${1//$'\n'/ }"); }
# Идёт ли обновление: без разбора всего состояния.
osup_busy() { _osup_paths; grep -qx 'status=running' "$OSUP_STATE" 2>/dev/null && osup_alive; }
osup_busy_text() { bi "идёт обновление Ubuntu — дождитесь окончания (goinstall покажет ход)" "an Ubuntu upgrade is running — wait until it finishes (goinstall shows the progress)"; }
osup_busy_refuse() { osup_busy || return 1; err "$(osup_busy_text)"; return 0; }

# Пункт есть: Ubuntu 20.04 или 22.04.
osup_applicable() { [ "$OS_ID" = ubuntu ] && case "$OS_VER" in 20.04|22.04) return 0 ;; *) return 1 ;; esac; }
# Отказ только по ОС может звать к пункту «o»: Ubuntu 20.04/22.04, не
# контейнер, обновление не идёт и не прервано, а на 24.04 продукт по ОС
# проходит (отказ goAmnezia pro по архитектуре обновлением не лечится).
osup_hint_ok() {  # osup_hint_ok <продукт>
    osup_applicable || return 1
    case $'\n'"$(OS_VER="$OSUP_TARGET" OS_MAJ="${OSUP_TARGET%%.*}" OS_MIN="$(( 10#${OSUP_TARGET#*.} ))" OS_PRETTY="Ubuntu ${OSUP_TARGET}" prod_os_check "$1" 2>/dev/null)" in *$'\n'must\|*) return 1 ;; esac
    [ -n "${OSUP_HINT_CONT:-}" ] || { if osup_container; then OSUP_HINT_CONT=yes; else OSUP_HINT_CONT=no; fi; }
    [ "$OSUP_HINT_CONT" = no ] || return 1
    _osup_paths; [ -e "$OSUP_STATE" ] || return 0
    grep -qx 'status=done' "$OSUP_STATE" 2>/dev/null
}
osup_hint_text() { bi "Обновить Ubuntu до ${OSUP_TARGET} можно из меню goinstall — пункт o (или goinstall --os-upgrade)." "Ubuntu can be upgraded to ${OSUP_TARGET} from the goinstall menu — item o (or goinstall --os-upgrade)."; }
# Повтор после сбоя можно и на выросшем выпуске (прыжок прошёл, оборвалось
# дальше): выпуск — между исходным и целевым. OSU уже загружен.
osup_resumable() {
    [ "$OS_ID" = ubuntu ] && [ "${OSU[status]:-}" = failed ] && [ -n "${OSU[from]:-}" ] || return 1
    [ "$(_osup_vnum "$OS_VER")" -ge "$(_osup_vnum "${OSU[from]}")" ] && [ "$(_osup_vnum "$OS_VER")" -le "$(_osup_vnum "$OSUP_TARGET")" ]
}
osup_container() {  # → OSUP_VIRT; rc 0 — контейнер
    local v
    v=$(systemd-detect-virt --container 2>/dev/null) || v=""
    v="${v%%$'\n'*}"
    if [ -n "$v" ] && [ "$v" != none ]; then OSUP_VIRT="$v"; return 0; fi
    v=$(systemd-detect-virt 2>/dev/null) || v=""
    OSUP_VIRT="${v%%$'\n'*}"; [ "$OSUP_VIRT" = none ] && OSUP_VIRT=""
    return 1
}
_osup_next() { case "$1" in 20.04) printf '22.04' ;; 22.04) printf '24.04' ;; *) printf '' ;; esac; }
_osup_vnum() { local v="${1%%[!0-9.]*}"; v="${v/./}"; v="${v%%.*}"; case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$((10#$v))" ;; esac; }
# Цепочка шагов: пакеты выпуска, прыжок, перезагрузка … завершение.
osup_plan() {
    case "$1" in
        20.04) OSUP_PLAN=(dist-20.04 rel-20.04 boot-22.04 dist-22.04 rel-22.04 boot-24.04 fin) ;;
        *)     OSUP_PLAN=(dist-22.04 rel-22.04 boot-24.04 fin) ;;
    esac
}
osup_step_title() {  # → UI_TX
    case "$1" in
        dist-*) ut "Пакеты ${1#dist-}" "${1#dist-} packages" ;;
        rel-*)  UI_TX="${1#rel-} → $(_osup_next "${1#rel-}")" ;;
        boot-*) ut "Перезагрузка" "Reboot" ;;
        fin)    ut "Источники apt, службы, боты" "apt sources, services, bots" ;;
        *)      UI_TX="$1" ;;
    esac
}
osup_step_done() { [[ "${OSU[t:$1]:-}" == *" "* ]]; }
osup_step_begin() {
    OSU[t:$1]="$(_osup_now)"; OSU[step]="$1"; osup_save
    osup_step_title "$1"; osup_log "── шаг: ${UI_TX} ($1)"
}
osup_step_end() {
    local s="${OSU[t:$1]:-}" now; now=$(_osup_now)
    s="${s%% *}"; [ -n "$s" ] || s="$now"
    OSU[t:$1]="$s $now"; osup_save
    osup_step_title "$1"; osup_log "── готово: ${UI_TX} за $(( now - s )) с"
}
# Длительность словами: «<1 мин», «14 мин», «1 ч 18 мин».
osup_dur() {  # → UI_TX
    local s="${1:-0}" m h
    case "$s" in ''|*[!0-9-]*) s=0 ;; esac
    [ "$s" -lt 0 ] && s=0
    m=$(( (s + 30) / 60 )); h=$(( m / 60 )); m=$(( m % 60 ))
    if [ "$s" -lt 60 ]; then ut "<1 мин" "<1 min"
    elif [ "$h" -gt 0 ]; then ut "${h} ч ${m} мин" "${h} h ${m} min"
    else ut "${m} мин" "${m} min"; fi
}
# Ход: OSUP_N (номер текущего шага), OSUP_M, OSUP_CUR, OSUP_CURT (начало текущего).
osup_progress() {
    local i l p prev=""
    osup_plan "${OSU[from]:-22.04}"
    OSUP_M=${#OSUP_PLAN[@]}; OSUP_N=$OSUP_M; OSUP_CUR=""; OSUP_CURT="${OSU[started]:-$(_osup_now)}"
    for ((i = 0; i < OSUP_M; i++)); do
        l="${OSUP_PLAN[$i]}"
        if osup_step_done "$l"; then prev="${OSU[t:$l]#* }"; continue; fi
        OSUP_N=$(( i + 1 )); OSUP_CUR="$l"
        if [ -n "${OSU[t:$l]:-}" ]; then OSUP_CURT="${OSU[t:$l]%% *}"; elif [ -n "$prev" ]; then OSUP_CURT="$prev"; fi
        break
    done
    # «Попробовать снова» начинает шаг заново: отметка запуска (kick) ставится
    # при каждом запуске и повторе, раньше неё текущий шаг не начат. Иначе
    # сразу после повтора — «идёт 2 мин» от первого входа в шаг.
    p=$(osup_num kick); [ "$p" -gt "$OSUP_CURT" ] && OSUP_CURT="$p"
    return 0
}

# Системные мелочи — отдельными функциями, тесты подменяют их заглушками в PATH.
_osup_free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024}'; }
_osup_mount() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $6}'; }
_osup_kernel() { printf '%s' "${GOINST_KERNEL:-$(uname -r 2>/dev/null)}"; }
# Кто держит замок dpkg/apt: «pid имя» или пусто.
osup_lock_holder() {
    local r="${GOINST_FS_ROOT:-}" f pid c
    # Без конвейера и без «|| f=""»: find выходит с 1, если процесс исчез
    # посреди обхода (dpkg плодит короткие), а найденное при этом верно.
    # Под pipefail «| head -1» с «||» стирал держателя — ровно когда замок занят.
    f=$(find "$r"/proc/[0-9]*/fd \( -lname '/var/lib/dpkg/lock*' -o -lname '/var/lib/apt/lists/lock' -o -lname '/var/cache/apt/archives/lock' \) -print -quit 2>/dev/null) || true
    f="${f%%$'\n'*}"
    [ -n "$f" ] || return 0
    pid="${f#"$r"/proc/}"; pid="${pid%%/*}"
    c=$(cat "$r/proc/$pid/comm" 2>/dev/null) || c=""
    printf '%s %s' "$pid" "${c:-?}"
}
# osup_lock_wait <секунд> — подождать, пока замок свободен; печатает держателя, если не дождались.
osup_lock_wait() {
    local max="${1:-0}" h t=0
    while :; do
        h=$(osup_lock_holder)
        [ -n "$h" ] || return 0
        if [ "$t" -ge "$max" ]; then printf '%s' "$h"; return 1; fi
        [ "$t" = 0 ] && [ "$max" -gt 0 ] && osup_log "замок apt держит ${h} — жду до ${max} с"
        sleep 5; t=$(( t + 5 ))
    done
}
_osup_ufw_active() { local s; s=$(LC_ALL=C ufw status 2>/dev/null) || s=""; grep -qi '^Status: active' <<<"$s"; }
# Порты SSH из настроек: признак ssh.socket в снимке «до» и запасной путь
# сверки, когда снимка нет. Сначала sshd -T — действующие настройки с
# Include. Нет его — разбор sshd_config и drop-in по правилам sshd:
# ListenAddress с портом слушает свой порт, без порта (в том числе «::») —
# порты Port; Port нет — 22. Нет ни sshd -T, ни файлов — пусто: нет и SSH.
osup_ssh_cfg_ports() {
    local r="${GOINST_FS_ROOT:-}" f t n any=0 out=""
    local -a P=() L=()
    if t=$(sshd -T 2>/dev/null) && [ -n "$t" ]; then
        out=$(sed -n -E 's/^listenaddress[[:space:]]+.*:([0-9]+)([[:space:]].*)?$/\1/p' <<<"$t")
        [ -n "$out" ] || out=$(sed -n -E 's/^port[[:space:]]+([0-9]+)[[:space:]]*$/\1/p' <<<"$t")
    fi
    if [ -z "$out" ]; then
        n=0
        for f in "$r/etc/ssh/sshd_config" "$r"/etc/ssh/sshd_config.d/*.conf; do
            [ -r "$f" ] || continue
            any=1
            # shellcheck disable=SC2207
            P+=($(sed -n -E 's/^[[:space:]]*[Pp]ort[[:space:]]*[=[:space:]][[:space:]]*([0-9]+).*/\1/p' "$f"))
            # ListenAddress host:port и [v6]:port (Д3).
            # shellcheck disable=SC2207
            L+=($(sed -n -E -e 's/^[[:space:]]*[Ll]isten[Aa]ddress[[:space:]]*[=[:space:]][[:space:]]*\[[^]]*\]:([0-9]+).*/\1/p' \
                            -e 's/^[[:space:]]*[Ll]isten[Aa]ddress[[:space:]]*[=[:space:]][[:space:]]*[^:[:space:]]+:([0-9]+)([[:space:]].*)?$/\1/p' "$f"))
            t=$(grep -c -E '^[[:space:]]*[Ll]isten[Aa]ddress[[:space:]]*[=[:space:]]' "$f" 2>/dev/null) || t=0
            n=$(( n + ${t:-0} ))
        done
        [ "$any" = 1 ] || return 0
        [ "${#P[@]}" -gt 0 ] || P=(22)
        # Адреса без порта (или ListenAddress нет вовсе) слушают порты Port.
        if [ "$n" -eq 0 ] || [ "$n" -gt "${#L[@]}" ]; then out="${P[*]} ${L[*]}"; else out="${L[*]}"; fi
    fi
    # shellcheck disable=SC2086
    out=$(printf '%s\n' $out | sort -un | tr '\n' ' ')
    printf '%s' "$out"
}
# Слушатель sshd — сам демон, а не процесс сессии: родитель 1 (0 — sshd
# первым процессом контейнера) или MainPID ssh.service/sshd.service.
# Процесса нет или /proc не читается — не судим, считаем демоном.
_osup_sshd_daemon() {
    local pid="$1" pp m u
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    pp=$(sed -n 's/^PPid:[[:space:]]*//p' "${GOINST_FS_ROOT:-}/proc/$pid/status" 2>/dev/null) || pp=""
    case "$pp" in ''|0|1) return 0 ;; esac
    for u in ssh.service sshd.service; do
        m=$(systemctl show -p MainPID "$u" 2>/dev/null) || m=""
        [ "${m#MainPID=}" = "$pid" ] && return 0
    done
    return 1
}
# osup_ssh_ports [--daemon] [порты] — TCP-порты, где слушает SSH: sshd, а
# systemd (на ssh.socket) — только на перечисленных портах (по умолчанию —
# из настроек). --daemon — снимок «до»: только сам демон. sshd сессии
# человека слушает порты пересылки X11 (127.0.0.1:6010) и ssh -R; после
# обновления сессии нет, и сверка звала бы её порты потерянными — ложная
# тревога и лишний перезапуск SSH. Поэтому sshd с чужим родителем не берём,
# и loopback с портом не из настроек — тоже. Демона не узнали вовсе (пусто)
# — снимок как прежде, все sshd: правка SSH может только убавлять
# перезапуски, а пустой снимок отправил бы сверку к настройкам. Сверка
# «после» судит мягко (любой sshd): строже — значит лишний перезапуск.
osup_ssh_ports() {
    local acc p a po pr pi out=" " all=" " dm=0
    [ "${1:-}" = --daemon ] && { dm=1; shift; }
    if [ "$#" -gt 0 ]; then acc=" $1 "; else acc=" $(osup_ssh_cfg_ports) "; fi
    _SCAN_STAMP=""; scan_listeners
    while IFS='|' read -r p a po pr pi; do
        [ "$p" = tcp ] || continue
        case "$pr" in
            sshd) ;;
            systemd) case "$acc" in *" $po "*) ;; *) continue ;; esac ;;
            *) continue ;;
        esac
        case "$all" in *" $po "*) ;; *) all+="$po " ;; esac
        if [ "$dm" = 1 ] && [ "$pr" = sshd ]; then
            _osup_sshd_daemon "$pi" || continue
            case "$a" in
                127.*|::1|::ffff:127.*) case "$acc" in *" $po "*) ;; *) continue ;; esac ;;
            esac
        fi
        case "$out" in *" $po "*) ;; *) out+="$po " ;; esac
    done <<<"$LISTENERS"
    [ "$out" = " " ] && out="$all"
    out="${out# }"; printf '%s' "${out% }"
}
# Стоящие пакеты групп компонентов (comp_spec), без пакетов конкретного python:
# python3.10 на новом выпуске нет, ручная пометка держала бы старый python.
osup_comp_installed() {
    local id spec pats p v s st pat
    local -a names=()
    while IFS='|' read -r p v s st; do
        [ -n "$p" ] || continue
        case "${st:1:1}" in i|U|F|W|t) names+=("${p%%:*}") ;; esac
    done < <(_comp_dpkg)
    pats=""
    for id in "${COMP_IDS[@]}"; do
        spec=$(comp_spec "$id"); pats+=" ${spec%%|*}"; spec="${spec#*|}"; pats+=" ${spec%%|*}"
    done
    set -f
    for p in "${names[@]}"; do
        for pat in $pats; do
            case "$pat" in *@py*) continue ;; esac
            # shellcheck disable=SC2053
            [[ "$p" == $pat ]] && { printf '%s\n' "$p"; break; }
        done
    done
    set +f
}
_osup_has_pkg() { grep -qx "$1" <<<"$OSUP_PKGS"; }
_osup_pkgs_now() { OSUP_PKGS=$(_comp_dpkg | awk -F'|' '$1 != "" && substr($4,2,1) ~ /[iUFWt]/ {sub(/:.*/, "", $1); print $1}'); }
# Службы, которые сверяются до и после.
osup_units_watch() {
    local p u out=" "
    for u in nginx docker dnsdist warp-svc x-ui telemt netfilter-persistent; do out+="$u "; done
    for p in "${PRODUCTS[@]}"; do
        prod_installed "$p" || continue
        for u in $(prod_units "$p"); do case "$out" in *" $u "*) ;; *) out+="$u " ;; esac; done
    done
    printf '%s' "$out"
}
_osup_docker_names() { command -v docker >/dev/null 2>&1 || return 0; _comp_t 10 docker ps --format '{{.Names}}' 2>/dev/null; }
_osup_prompt() { sed -n -E 's/^[[:space:]]*Prompt[[:space:]]*=[[:space:]]*([a-z]+).*/\1/p' "$OSUP_RU" 2>/dev/null | head -1; }
_osup_set_prompt() {  # _osup_set_prompt <значение>; без sed -i: на macOS он другой
    local tmp="$OSUP_RU.goinst"
    [ -f "$OSUP_RU" ] || return 0
    sed -E "s/^([[:space:]]*Prompt[[:space:]]*=[[:space:]]*).*/\1$1/" "$OSUP_RU" > "$tmp" 2>/dev/null && cat "$tmp" > "$OSUP_RU" 2>/dev/null
    rm -f "$tmp"
}

# apt-get исполнителя — ТОЛЬКО здесь. Это не «Компоненты»: обновление выпуска
# по определению dist-upgrade. Страж набора разрешает эти четыре вида и только
# в этой функции.
osup_apt() {
    local what="$1"; shift
    case "$what" in
        update)  apt-get -o DPkg::Lock::Timeout=900 update ;;
        dist)    apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y dist-upgrade ;;
        fix)     apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -f -y install ;;
        install) apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y --no-install-recommends --no-remove install "$@" ;;
        *) return 64 ;;
    esac >> "$OSUP_LOG" 2>&1 </dev/null
}

# ── проверка перед запуском ─────────────────────────────────────────────
# osup_check [секунд ждать замок] → OSUP_CHK («ok|…», «warn|…», «bad|…»,
# «info|…», «do|…» — что goInstaller сделает сам), OSUP_BAD, OSUP_CONT.
osup_check() {
    local wait="${1:-0}" r="${GOINST_FS_ROOT:-}" v free b out h n name l mem
    OSUP_CHK=(); OSUP_BAD=0; OSUP_CONT=0
    _osc() { OSUP_CHK+=("$1|$2"); [ "$1" = bad ] && OSUP_BAD=$(( OSUP_BAD + 1 )); return 0; }
    _osup_paths
    if [ "$OS_ID" != ubuntu ]; then _osc bad "$(bi "обновление выпуска — только для Ubuntu (здесь ${OS_PRETTY:-$OS_ID})" "release upgrade is for Ubuntu only (this is ${OS_PRETTY:-$OS_ID})")"
    elif ! osup_applicable && ! osup_resumable; then _osc bad "$(bi "обновление — с Ubuntu 20.04 и 22.04 (здесь ${OS_PRETTY:-$OS_VER})" "the upgrade starts from Ubuntu 20.04 or 22.04 (this is ${OS_PRETTY:-$OS_VER})")"; fi
    if osup_container; then
        OSUP_CONT=1
        _osc bad "$(bi "контейнер (${OSUP_VIRT}): ядро задаёт хостер, обновить выпуск отсюда нельзя — переустановите сервер на 24.04 в панели хостера" "a container (${OSUP_VIRT}): the host sets the kernel, the release cannot be upgraded from here — reinstall the server with 24.04 in the hosting panel")"
    elif [ -n "${OSUP_VIRT:-}" ]; then
        _osc ok "$(bi "виртуалка ${OSUP_VIRT^^}" "${OSUP_VIRT^^} virtual machine")"
    fi
    free=$(_osup_free_mb /); case "$free" in ''|*[!0-9]*) free="" ;; esac
    if [ -n "$free" ]; then
        if [ "$free" -lt 5120 ]; then _osc bad "$(bi "на / свободно $(( free / 1024 )) ГБ, нужно не меньше 5 ГБ" "only $(( free / 1024 )) GB free on /, at least 5 GB is needed")"
        elif [ "$free" -lt 8192 ]; then _osc warn "$(bi "на / свободно $(( free / 1024 )) ГБ — впритык: обновление занимает до 4 ГБ" "$(( free / 1024 )) GB free on / — tight: the upgrade takes up to 4 GB")"
        else _osc ok "$(bi "$(( free / 1024 )) ГБ свободно" "$(( free / 1024 )) GB free")"; fi
    fi
    if [ "$(_osup_mount /boot)" = /boot ]; then
        b=$(_osup_free_mb /boot)
        case "$b" in ''|*[!0-9]*) ;; *) [ "$b" -lt 300 ] && _osc bad "$(bi "на /boot свободно ${b} МБ, нужно не меньше 300 МБ — удалите старые ядра" "only ${b} MB free on /boot, at least 300 MB is needed — remove old kernels")" ;; esac
    fi
    out=$(dpkg --audit 2>/dev/null) || true
    if [ -n "$out" ]; then _osc bad "$(bi "dpkg не в порядке: ${out%%$'\n'*} — dpkg --configure -a" "dpkg is not in order: ${out%%$'\n'*} — dpkg --configure -a")"; fi
    if h=$(osup_lock_wait "$wait"); then _osc ok "$(bi "apt свободен" "apt is free")"
    else
        name="${h#* }"
        case "$name" in unattended-upgr*) _osc bad "$(bi "идут автообновления (unattended-upgrades) — подождите и откройте снова" "automatic updates are running (unattended-upgrades) — wait and open again")" ;;
            *) _osc bad "$(bi "apt занят процессом ${name} (${h%% *}) — подождите и откройте снова" "apt is busy with ${name} (${h%% *}) — wait and open again")" ;; esac
    fi
    if _comp_t 15 curl -sf -o /dev/null --max-time 15 "${GOINST_OSUP_META:-https://changelogs.ubuntu.com/meta-release-lts}" 2>/dev/null; then
        _osc ok "$(bi "changelogs.ubuntu.com отвечает" "changelogs.ubuntu.com answers")"
    else
        _osc bad "$(bi "нет связи с changelogs.ubuntu.com — без неё штатная программа не найдёт новый выпуск" "changelogs.ubuntu.com is unreachable — without it the upgrader cannot find the new release")"
    fi
    mem=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' "$r/proc/meminfo" 2>/dev/null) || mem=""
    case "$mem" in ''|*[!0-9]*) ;; *) [ "$mem" -lt 1000 ] && _osc warn "$(bi "памяти ${mem} МБ — обновление пойдёт медленнее" "${mem} MB of memory — the upgrade will be slower")" ;; esac
    v=$(_osup_prompt)
    if [ -n "$v" ] && [ "$v" != lts ]; then _osc warn "$(bi "в release-upgrades стоит Prompt=${v} — на время обновления будет lts" "release-upgrades has Prompt=${v} — it is lts for the upgrade")"; fi
    # Что стоит и что с ним будет. Сначала — что goInstaller сделает сам.
    _osup_pkgs_now
    if [ "$OSUP_FIX_LISTS" = 1 ]; then
        out=""
        for l in $OSUP_LISTS; do
            [ -e "$OSUP_SL/$l" ] || [ -e "$OSUP_SL/$l.distUpgrade" ] || continue
            case "$l" in
                godns-dnsdist.list) out+="${out:+, }dnsdist (goDNS pro)" ;;
                cloudflare-client.list) out+="${out:+, }cloudflare-warp (goWARP pro)" ;;
                cloudflared.list) out+="${out:+, }cloudflared (goVLESS pro)" ;;
            esac
        done
        [ -n "$out" ] && _osc do "$(bi "вернёт на 24.04 источники apt: ${out}" "brings the apt sources back on 24.04: ${out}")"
    fi
    _osc do "$(bi "на время обновления покажет ход при входе по SSH (${OSUP_HOOK#"${GOINST_FS_ROOT:-}"}, уберётся сам)" "shows the progress at SSH login while upgrading (${OSUP_HOOK#"${GOINST_FS_ROOT:-}"}, removed by itself)")"
    if grep -q '^libnginx-mod-' <<<"$OSUP_PKGS"; then
        _osc do "$(bi "сохранит модули nginx — без них nginx на 24.04 не запустится" "keeps the nginx modules — without them nginx does not start on 24.04")"
    fi
    if _osup_has_pkg ufw && _osup_has_pkg iptables-persistent; then
        if _osup_ufw_active; then
            _osc do "$(bi "сохранит правила файрвола (netfilter-persistent save)" "saves the firewall rules (netfilter-persistent save)")"
            _osc warn "$(bi "ufw удалится на 24.04 (несовместим с iptables-persistent goKaskad pro). Перед этим goInstaller сохранит текущие правила (netfilter-persistent save), чтобы они загружались и без ufw. Управлять ими через ufw после этого нельзя" "ufw is removed on 24.04 (it conflicts with goKaskad pro's iptables-persistent). Before that goInstaller saves the current rules (netfilter-persistent save) so they load without ufw. They cannot be managed with ufw afterwards")"
        else
            _osc info "$(bi "ufw удалится на 24.04 — он несовместим с iptables-persistent (goKaskad pro). Правила из /etc/iptables/rules.v4 останутся и будут загружаться" "ufw is removed on 24.04 — it conflicts with iptables-persistent (goKaskad pro). The rules in /etc/iptables/rules.v4 stay and keep loading")"
        fi
    fi
    comp_bots_load
    for ((n = 0; n < ${#CB_ID[@]}; n++)); do
        _osc info "$(bi "бот $(prod_name "${CB_ID[$n]}") после обновления не запустится, пока не переустановить его в меню продукта: $(comp_bot_fix "${CB_ID[$n]}")" "the $(prod_name "${CB_ID[$n]}") bot will not start after the upgrade until it is reinstalled from the product menu: $(comp_bot_fix "${CB_ID[$n]}")")"
    done
    if prod_installed gokaskad; then
        v=$(prod_version gokaskad 2>/dev/null) || v=""
        if [ "${v%%.*}" = 3 ]; then _osc info "$(bi "после обновления запустите gokaskad — он предложит перейти на nftables" "after the upgrade run gokaskad — it offers to move to nftables")"
        else _osc info "$(bi "после обновления запустите gokaskad и проверьте проброс" "after the upgrade run gokaskad and check the forwarding")"; fi
    fi
    out=$(dkms status 2>/dev/null | sed -n -E 's/^([^,/: ]+).*/\1/p' | sort -u | tr '\n' ' ') || out=""
    out="${out% }"
    [ -n "$out" ] && _osc info "$(bi "модуль ${out} пересоберётся под новое ядро: goInstaller поставит заголовки ядра" "the ${out} module is rebuilt for the new kernel: goInstaller installs the kernel headers")"
    if _osup_has_pkg docker.io || _osup_has_pkg docker-ce; then
        _osc info "$(bi "контейнеры с автоперезапуском поднимутся сами" "containers with automatic restart come back by themselves")"
    fi
    return 0
}

# ── запуск ──────────────────────────────────────────────────────────────
# Снимок «до»: сверка на завершении идёт по нему. При повторе после сбоя он
# уже есть и не переписывается: «до» — это до первой попытки.
osup_before() {
    local u
    mkdir -p "$OSUP_BEFORE" 2>/dev/null || return 1
    _comp_dpkg > "$OSUP_BEFORE/dpkg" 2>/dev/null
    apt-mark showmanual > "$OSUP_BEFORE/manual" 2>/dev/null
    osup_comp_installed > "$OSUP_BEFORE/comp" 2>/dev/null
    : > "$OSUP_BEFORE/units"
    for u in $(osup_units_watch); do [ "$(unit_state "$u")" = run ] && printf '%s\n' "$u" >> "$OSUP_BEFORE/units"; done
    _osup_docker_names > "$OSUP_BEFORE/docker"
    _osup_pkgs_now
    if _osup_has_pkg ufw; then echo 1; else echo 0; fi > "$OSUP_BEFORE/ufw"
    ls -1 "$OSUP_SL" > "$OSUP_BEFORE/sources" 2>/dev/null
    osr VERSION_CODENAME > "$OSUP_BEFORE/codename"
    _osup_prompt > "$OSUP_BEFORE/prompt"
    osup_ssh_ports --daemon > "$OSUP_BEFORE/ssh"
    return 0
}
osup_unit_text() {
    cat <<UNIT
[Unit]
Description=goInstaller: обновление Ubuntu до ${OSUP_TARGET}, шаг за запуск
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=0
Environment=DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
Environment=GOINST_DIR=${GOINST_DIR}
ExecStart=/bin/bash ${OSUP_RUNNER} --os-upgrade-run
StandardOutput=append:${OSUP_LOG}
StandardError=append:${OSUP_LOG}

[Install]
WantedBy=multi-user.target
UNIT
}
# osup_start — запустить (или повторить после сбоя). rc 0 — служба запущена;
# иначе причина в OSUP_ERR. Проверка — заново, без ожидания замка.
osup_start() {
    local retry=0 a=1 src="" k marked
    OSUP_ERR=""
    _osup_paths
    if osup_load; then
        case "${OSU[status]:-}" in
            running) OSUP_ERR=$(bi "обновление уже идёт" "the upgrade is already running"); return 1 ;;
            failed)  retry=1; a=$(( $(osup_num attempt) + 1 ))
                     if [ "$a" -gt 3 ]; then OSUP_ERR=$(bi "попыток больше нет — смотрите журнал ${OSUP_LOG}" "no attempts left — see the log ${OSUP_LOG}"); return 1; fi ;;
        esac
    fi
    osup_check 0
    if [ "$OSUP_BAD" -gt 0 ]; then
        for k in "${OSUP_CHK[@]}"; do case "$k" in bad\|*) OSUP_ERR="${k#bad|}"; break ;; esac; done
        return 1
    fi
    # Копия скрипта для службы — ТОЙ ЖЕ версии, что запущена: старая не знает
    # --os-upgrade-run, и служба падала бы на каждой загрузке. Из bash <(curl …)
    # $0 — не файл, тогда goinstall, но только этой же версии.
    if [ -f "$GOINST_SELF_PATH" ] && grep -qx "GOINST_VERSION=\"${GOINST_VERSION}\"" "$GOINST_SELF_PATH" 2>/dev/null; then src="$GOINST_SELF_PATH"
    elif [ -f "$GOINST_BIN" ] && grep -qx "GOINST_VERSION=\"${GOINST_VERSION}\"" "$GOINST_BIN" 2>/dev/null; then src="$GOINST_BIN"; fi
    if [ -z "$src" ]; then OSUP_ERR=$(bi "сначала обновите команду goinstall (запустите goinstall) — для службы нужен скрипт версии ${GOINST_VERSION}" "update the goinstall command first (run goinstall) — the unit needs the ${GOINST_VERSION} script"); return 1; fi
    mkdir -p "$OSUP_DIR" 2>/dev/null && chmod 700 "$OSUP_DIR" 2>/dev/null || { OSUP_ERR=$(bi "не создать ${OSUP_DIR}" "cannot create ${OSUP_DIR}"); return 1; }
    if [ "$retry" = 0 ] || [ ! -d "$OSUP_BEFORE" ]; then rm -rf "$OSUP_BEFORE"; osup_before || { OSUP_ERR=$(bi "не записать снимок «до»" "cannot write the “before” snapshot"); return 1; }; fi
    if [ "$retry" = 1 ]; then
        # Повтор: сделанные шаги остаются, оборванный пойдёт заново. Начатый
        # прыжок, после которого выпуск уже вырос, остаётся начатым: его
        # пакеты исполнитель доведёт до отметки (обрыв после base-files).
        for k in "${!OSU[@]}"; do
            case "$k" in
                t:rel-*) [[ "${OSU[$k]}" == *" "* ]] && continue
                         [ "$(_osup_vnum "$OS_VER")" -gt "$(_osup_vnum "${k#t:rel-}")" ] || unset "OSU[$k]" ;;
                t:*) [[ "${OSU[$k]}" == *" "* ]] || unset "OSU[$k]" ;;
                n:*) unset "OSU[$k]" ;;
            esac
        done
        osup_set status running; osup_set attempt "$a"; osup_set reboots 0; osup_set msg ""; osup_set finished ""; osup_set step ""; osup_set seen 0
        OSU_NOTES=(); OSU_DID=()
        osup_log "=== повтор, попытка ${a}"
    else
        OSU=(); OSU_NOTES=(); OSU_DID=()
        osup_set status running; osup_set from "$OS_VER"; osup_set target "$OSUP_TARGET"; osup_set started "$(_osup_now)"
        osup_set reboots 0; osup_set attempt 1; osup_set seen 0
        : > "$OSUP_LOG" 2>/dev/null; chmod 600 "$OSUP_LOG" 2>/dev/null
        osup_log "=== запуск: ${OS_PRETTY} → ${OSUP_TARGET}"
    fi
    if ! cp -f "$src" "$OSUP_RUNNER" 2>/dev/null; then OSUP_ERR=$(bi "не скопировать скрипт в ${OSUP_RUNNER}" "cannot copy the script to ${OSUP_RUNNER}"); return 1; fi
    chmod 700 "$OSUP_RUNNER" 2>/dev/null
    # Свои конфиги продуктов (nginx.conf goTelegram pro и др.) — не заменять.
    mkdir -p "$(dirname "$OSUP_APTCONF")" 2>/dev/null
    printf '%s\n' '// goInstaller: на время обновления Ubuntu — оставлять свои файлы настроек. Убирается по окончании.' \
        'Dpkg::Options { "--force-confdef"; "--force-confold"; };' > "$OSUP_APTCONF" 2>/dev/null \
        || { OSUP_ERR=$(bi "не записать ${OSUP_APTCONF}" "cannot write ${OSUP_APTCONF}"); return 1; }
    # Только LTS: при Prompt=normal апгрейдер ушёл бы на промежуточный выпуск.
    [ "$(_osup_prompt)" = lts ] || _osup_set_prompt lts
    # Авто-пакеты групп компонентов — вручную: иначе апгрейдер снесёт их как
    # ненужные (libnginx-mod-stream → nginx не стартует). Пометку не снимаем.
    marked=$(grep -vxF -f "$OSUP_BEFORE/manual" "$OSUP_BEFORE/comp" 2>/dev/null) || marked=""
    [ -s "$OSUP_BEFORE/manual" ] || marked=$(cat "$OSUP_BEFORE/comp" 2>/dev/null)
    printf '%s\n' "$marked" | sed '/^$/d' > "$OSUP_BEFORE/marked"
    if [ -s "$OSUP_BEFORE/comp" ]; then
        # shellcheck disable=SC2046
        apt-mark manual $(cat "$OSUP_BEFORE/comp") >> "$OSUP_LOG" 2>&1 || osup_log "apt-mark manual: ошибка"
    fi
    mkdir -p "$(dirname "$OSUP_UNITF")" 2>/dev/null
    osup_unit_text > "$OSUP_UNITF" 2>/dev/null || { OSUP_ERR=$(bi "не записать ${OSUP_UNITF}" "cannot write ${OSUP_UNITF}"); osup_cleanup; return 1; }
    chmod 644 "$OSUP_UNITF" 2>/dev/null
    # Отметка запуска: до start --no-block службы ещё нет в очереди, а
    # «идёт» уже записано — osup_alive по ней не скажет «упал».
    osup_set kick "$(_osup_now)"
    osup_save
    osup_hook_write
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "$OSUP_UNIT" >/dev/null 2>&1 || osup_log "systemctl enable ${OSUP_UNIT}: ошибка — после перезагрузки служба не пойдёт"
    if ! systemctl start --no-block "$OSUP_UNIT" >/dev/null 2>&1; then
        osup_set status failed; osup_set msg "$(bi "служба не запустилась — journalctl -u ${OSUP_UNIT}" "the unit did not start — journalctl -u ${OSUP_UNIT}")"; osup_save
        OSUP_ERR="${OSU[msg]}"; osup_cleanup; return 1
    fi
    return 0
}
# Уборка: временный apt.conf, Prompt, служба, копия скрипта. Состояние,
# журнал и снимок «до» остаются.
osup_cleanup() {
    local p
    _osup_paths
    rm -f "$OSUP_APTCONF" 2>/dev/null
    p=$(cat "$OSUP_BEFORE/prompt" 2>/dev/null) || p=""
    [ -n "$p" ] && [ "$(_osup_prompt)" != "$p" ] && _osup_set_prompt "$p"
    systemctl disable "$OSUP_UNIT" >/dev/null 2>&1
    rm -f "$OSUP_UNITF" 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1
    # Упавшая служба без файла юнита висит в systemctl --failed до
    # перезагрузки («not-found failed»): мониторинг видел бы её вечно.
    systemctl reset-failed "$OSUP_UNIT" >/dev/null 2>&1
    rm -f "$OSUP_RUNNER" 2>/dev/null
    return 0
}

# ── исполнитель: один шаг за запуск ─────────────────────────────────────
osup_fail() {
    osup_set status failed; osup_set msg "$1"; osup_set finished "$(_osup_now)"; osup_save
    osup_log "ОСТАНОВ: $1"
    osup_cleanup
    return 1
}
# Перезагрузка — только в настроенную систему: недонастроенный dpkg после
# перезагрузки — ровно тот случай, когда SSH может не вернуться. rc 1 — нет.
osup_reboot() {
    local out
    out=$(dpkg --audit 2>/dev/null) || true
    if [ -n "$out" ]; then
        osup_log "перед перезагрузкой dpkg недонастроен (${out%%$'\n'*}) — восстанавливаю"
        if ! osup_recover force; then
            osup_fail "$(bi "dpkg недонастроен (${out%%$'\n'*}) — сервер не перезагружаю: dpkg --configure -a, ${OSUP_LOG}" "dpkg is not configured (${out%%$'\n'*}) — not rebooting the server: dpkg --configure -a, ${OSUP_LOG}")"
            return 1
        fi
    fi
    osup_save
    osup_log "перезагрузка: $1"
    sync 2>/dev/null
    if ! systemctl reboot >/dev/null 2>&1; then
        osup_fail "$(bi "перезагрузка не прошла (systemctl reboot) — перезагрузите сервер сами и нажмите «Попробовать снова»" "the reboot failed (systemctl reboot) — reboot the server yourself and choose “Try again”")"
        return 1
    fi
    local w="${GOINST_OSUP_REBOOT_WAIT:-600}"
    case "$w" in ''|*[!0-9]*) w=600 ;; esac
    sleep "$w"
    # Живы через 10 минут — перезагрузки не было: не висеть «идёт» с
    # включённой службой, которой никто не позовёт до ручной перезагрузки.
    if [ "$w" -gt 0 ]; then
        osup_fail "$(bi "сервер не перезагрузился за ${w} с после systemctl reboot — перезагрузите его сами и нажмите «Попробовать снова»" "the server did not reboot within ${w} s after systemctl reboot — reboot it yourself and choose “Try again”")"
        return 1
    fi
    return 0
}
_osup_rr() { [ -e "${GOINST_FS_ROOT:-}/var/run/reboot-required" ]; }
# Обрыв посреди установки (перезагрузка хостером, питание): dpkg недонастроен.
# force — восстанавливать и при пустом dpkg --audit (апгрейдер вышел с
# ошибкой, прыжок оборван после смены выпуска); тогда rc 1 и при ошибке шага.
osup_recover() {
    local r="${GOINST_FS_ROOT:-}" out upd="" bad=0
    out=$(dpkg --audit 2>/dev/null) || true
    [ -n "$(ls -A "$r/var/lib/dpkg/updates" 2>/dev/null)" ] && upd=1
    [ -z "$out" ] && [ -z "$upd" ] && [ "${1:-}" != force ] && return 0
    osup_log "восстановление dpkg${out:+: ${out%%$'\n'*}}"
    dpkg --force-confdef --force-confold --configure -a >> "$OSUP_LOG" 2>&1 </dev/null || { bad=1; osup_log "dpkg --configure -a: ошибка"; }
    osup_apt fix || { bad=1; osup_log "apt-get -f install: ошибка"; }
    out=$(dpkg --audit 2>/dev/null) || true
    if [ -n "$out" ]; then osup_log "восстановление не помогло: ${out%%$'\n'*}"; return 1; fi
    [ "${1:-}" = force ] && [ "$bad" = 1 ] && return 1
    osup_log "восстановление dpkg: готово"
    return 0
}
# Причина неудачного прыжка — из журнала апгрейдера. Его нет, если апгрейдер
# не стартовал (нет связи с changelogs.ubuntu.com) — тогда ссылка на свой
# журнал, где вывод do-release-upgrade; есть — оба.
osup_dru_reason() {  # <rc> <выпуск>
    local r="${GOINST_FS_ROOT:-}" l j="${OSUP_LOG}"
    l=$(grep -E 'ERROR|Could not|No new release' "$r/var/log/dist-upgrade/main.log" 2>/dev/null) || l=""
    l="${l##*$'\n'}"; l="${l#*ERROR }"; l="${l:0:160}"
    [ -e "$r/var/log/dist-upgrade/main.log" ] && j+=", /var/log/dist-upgrade/main.log"
    if [ -n "$l" ]; then bi "do-release-upgrade (код $1): ${l}" "do-release-upgrade (code $1): ${l}"
    else bi "do-release-upgrade вышел с кодом $1, выпуск остался $2 — ${j}" "do-release-upgrade exited with code $1, the release stayed $2 — ${j}"; fi
}
# Можно ли прыгать с выпуска $1: выпуск тот же, что решили, и ниже целевого.
# На 24.04 и выше do-release-upgrade не запускается никогда: там Prompt=lts
# предлагает 26.04.
osup_dru_ok() {
    os_detect
    [ "$OS_VER" = "$1" ] && [ -n "$(_osup_next "$OS_VER")" ] && [ "$(_osup_vnum "$OS_VER")" -lt "$(_osup_vnum "$OSUP_TARGET")" ]
}
# Единственный вызов do-release-upgrade. rc 99 — не звали: выпуск не тот.
osup_dru() {  # osup_dru <выпуск, с которого прыжок>
    if ! osup_dru_ok "$1"; then osup_log "перед прыжком выпуск ${OS_VER:-?} (ждали $1) — do-release-upgrade не запускаю"; return 99; fi
    do-release-upgrade -f DistUpgradeViewNonInteractive >> "$OSUP_LOG" 2>&1 </dev/null
}
# Исполнитель — под замком: два сразу не идут (два «1» подряд, ручной
# --os-upgrade-run при работающей службе). flock есть в util-linux; без него —
# по живому run.pid.
osup_run() {
    local rc fd p
    _osup_paths
    OSUP_IN_RUNNER=1
    mkdir -p "$OSUP_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        if { exec {fd}>>"$OSUP_DIR/run.lock"; } 2>/dev/null && ! flock -n "$fd"; then
            osup_log "исполнитель уже работает — второй не запускаю"; return 0
        fi
    elif p=$(osup_runner_pid) && [ "$p" != "$$" ]; then
        osup_log "исполнитель уже работает (pid ${p}) — второй не запускаю"; return 0
    fi
    printf '%s\n' "$$" > "$OSUP_DIR/run.pid" 2>/dev/null
    _osup_run; rc=$?
    rm -f "$OSUP_DIR/run.pid" 2>/dev/null
    return "$rc"
}
_osup_run() {
    local i rc
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
    if ! osup_load; then osup_cleanup; return 0; fi
    if [ "${OSU[status]:-}" != running ]; then osup_log "статус ${OSU[status]:-?} — служба выключается"; osup_cleanup; return 0; fi
    os_detect
    osup_set reboots $(( $(osup_num reboots) + 1 )); osup_save
    osup_log "=== запуск #${OSU[reboots]}: ${OS_PRETTY}, ядро $(_osup_kernel)"
    if [ "${OSU[reboots]}" -gt 8 ]; then osup_fail "$(bi "круг перезагрузок: больше 8 запусков без итога" "a reboot loop: more than 8 runs without a result")"; return 1; fi
    # Закончилась перезагрузка.
    case "${OSU[step]:-}" in boot-*) osup_step_end "${OSU[step]}" ;; esac
    osup_recover || { osup_fail "$(bi "dpkg не в порядке и не восстановился — dpkg --audit" "dpkg is broken and did not recover — dpkg --audit")"; return 1; }
    # Выпуск перечитывается после каждого шага, меняющего пакеты: шаг,
    # сменивший выпуск, — повод решить заново, а не идти дальше по старому.
    for ((i = 0; i < 4; i++)); do
        _osup_pass; rc=$?
        [ "$rc" -eq 10 ] || return "$rc"
    done
    osup_fail "$(bi "выпуск меняется по ходу обновления — ${OSUP_LOG}" "the release keeps changing during the upgrade — ${OSUP_LOG}")"
    return 1
}
# Один проход решения. rc: 0 — на этот запуск всё (перезагрузка или итог),
# 1 — прервано, 10 — выпуск сменился по ходу, решить заново.
_osup_pass() {
    local ver rc l x n h nv b out
    os_detect; ver="$OS_VER"
    osup_plan "${OSU[from]:-$ver}"
    if [ -n "${OSU[from]:-}" ] && [ "$(_osup_vnum "$ver")" -lt "$(_osup_vnum "${OSU[from]}")" ]; then
        osup_fail "$(bi "неожиданный выпуск ${ver:-?}" "unexpected release ${ver:-?}")"; return 1
    fi
    # Прыжок начат, а выпуск уже вырос (обрыв после распаковки base-files,
    # перезагрузка хостером): восстановление, пакеты нового выпуска,
    # перезагрузка, если её просят, — и только потом отметка прыжка.
    for l in "${OSUP_PLAN[@]}"; do
        case "$l" in rel-*) ;; *) continue ;; esac
        x="${l#rel-}"
        [ -n "${OSU[t:$l]:-}" ] || continue
        osup_step_done "$l" && continue
        [ "$(_osup_vnum "$ver")" -gt "$(_osup_vnum "$x")" ] || continue
        osup_log "прыжок ${x} не отмечен, а выпуск уже ${ver} — довожу пакеты"
        osup_recover force || { osup_fail "$(bi "прыжок ${x} → ${ver} оборван, dpkg не восстановился — сервер не перезагружаю; dpkg --audit, ${OSUP_LOG}" "the ${x} → ${ver} jump broke off and dpkg did not recover — not rebooting; dpkg --audit, ${OSUP_LOG}")"; return 1; }
        osup_apt update || osup_log "apt-get update: код $?"
        osup_apt dist; rc=$?
        [ "$rc" -eq 0 ] || { osup_fail "$(bi "прыжок ${x} → ${ver} оборван, пакеты ${ver} не обновились (dist-upgrade, код ${rc}) — сервер не перезагружаю; ${OSUP_LOG}" "the ${x} → ${ver} jump broke off, the ${ver} packages did not upgrade (dist-upgrade, code ${rc}) — not rebooting; ${OSUP_LOG}")"; return 1; }
        os_detect; [ "$OS_VER" = "$ver" ] || { osup_log "после пакетов выпуск ${OS_VER}"; return 10; }
        b="boot-$ver"
        if _osup_rr; then osup_step_begin "$b"; osup_reboot "$(bi "пакеты ${ver} просят перезагрузку" "the ${ver} packages ask for a reboot")"; return $?; fi
        osup_step_end "$l"
        if ! osup_step_done "$b"; then osup_step_begin "$b"; osup_step_end "$b"; fi
        return 10
    done
    if [ "$ver" = "$OSUP_TARGET" ]; then
        if _osup_rr && ! osup_step_done "boot-$ver"; then osup_step_begin "boot-$ver"; osup_reboot "$(bi "пакеты просят перезагрузку" "the packages ask for a reboot")"; return $?; fi
        osup_finish; return 0
    fi
    case "$ver" in 20.04|22.04) ;; *) osup_fail "$(bi "неожиданный выпуск ${ver:-?}" "unexpected release ${ver:-?}")"; return 1 ;; esac
    # Пакеты текущего выпуска. Отметка — только после успеха.
    if ! osup_step_done "dist-$ver"; then
        osup_step_begin "dist-$ver"
        osup_apt update || osup_log "apt-get update: код $?"
        osup_apt dist; rc=$?
        [ "$rc" -eq 0 ] || { osup_fail "$(bi "обновление пакетов ${ver} (dist-upgrade) вышло с кодом ${rc} — ${OSUP_LOG}" "upgrading the ${ver} packages (dist-upgrade) exited with code ${rc} — ${OSUP_LOG}")"; return 1; }
        if ! command -v do-release-upgrade >/dev/null 2>&1; then
            osup_apt install ubuntu-release-upgrader-core
            command -v do-release-upgrade >/dev/null 2>&1 || { osup_fail "$(bi "нет do-release-upgrade и не поставился ubuntu-release-upgrader-core" "no do-release-upgrade and ubuntu-release-upgrader-core did not install")"; return 1; }
        fi
        osup_step_end "dist-$ver"
        os_detect; [ "$OS_VER" = "$ver" ] || { osup_log "после пакетов ${ver} выпуск ${OS_VER}"; return 10; }
        if _osup_rr; then osup_reboot "$(bi "пакеты просят перезагрузку" "the packages ask for a reboot")"; return $?; fi
    fi
    # Прыжок на следующий выпуск.
    l="rel-$ver"; nv=$(_osup_next "$ver")
    n=$(osup_num "n:$l")
    if [ -n "${OSU[t:$l]:-}" ]; then
        # Был начат и оборвался, выпуск прежний: пакеты заново и один повтор.
        if [ "$n" -ge 2 ]; then osup_fail "$(bi "прыжок ${ver} → ${nv} оборвался дважды — ${OSUP_LOG}" "the ${ver} → ${nv} jump broke off twice — ${OSUP_LOG}")"; return 1; fi
        osup_log "прыжок ${ver} → ${nv} оборвался — пакеты заново и повтор"
        osup_apt update || osup_log "apt-get update: код $?"
        osup_apt dist || { osup_fail "$(bi "после обрыва пакеты ${ver} не обновились — ${OSUP_LOG}" "after the break the ${ver} packages did not upgrade — ${OSUP_LOG}")"; return 1; }
        # Апгрейдер мог успеть переписать источники на новый выпуск — тогда
        # этот dist-upgrade сам довёл систему до него.
        os_detect; [ "$OS_VER" = "$ver" ] || { osup_log "после пакетов выпуск ${OS_VER} — прыжок не повторяю"; return 10; }
    fi
    # Сам do-release-upgrade замка не ждёт: на свежезагруженном сервере часто
    # работает apt-daily или unattended-upgrades.
    if ! h=$(osup_lock_wait "${GOINST_OSUP_LOCK_WAIT:-900}"); then
        osup_fail "$(bi "замок apt держит ${h#* } больше 15 минут" "${h#* } has held the apt lock for over 15 minutes")"; return 1
    fi
    # Пакеты, поставленные за это время (unattended-upgrades) или после
    # обрыва, просят перезагрузку — без неё do-release-upgrade отказывает.
    # Прыжок ещё не начат: попытка не сгорает.
    if _osup_rr; then osup_reboot "$(bi "перед прыжком пакеты просят перезагрузку" "the packages ask for a reboot before the jump")"; return $?; fi
    # ufw удалится на прыжке в 24.04 — сохранить текущие правила, чтобы они
    # загружались и без него.
    if [ "$nv" = "$OSUP_TARGET" ]; then
        _osup_pkgs_now
        if _osup_has_pkg ufw && _osup_has_pkg iptables-persistent && _osup_ufw_active; then
            netfilter-persistent save >> "$OSUP_LOG" 2>&1
            osup_log "netfilter-persistent save: код $?, правил в rules.v4: $(grep -c '^-A' "${GOINST_FS_ROOT:-}/etc/iptables/rules.v4" 2>/dev/null)"
        fi
    fi
    [ "$(_osup_prompt)" = lts ] || _osup_set_prompt lts
    # Последняя сверка выпуска — до отметки «начат».
    osup_dru_ok "$ver" || { osup_log "перед прыжком выпуск ${OS_VER:-?} (ждали ${ver}) — do-release-upgrade не запускаю"; return 10; }
    OSU[n:$l]=$(( n + 1 ))
    osup_step_begin "$l"
    osup_dru "$ver"; rc=$?
    [ "$rc" -eq 99 ] && return 10
    os_detect
    osup_log "do-release-upgrade: код ${rc}, выпуск ${OS_VER}"
    if [ "$(_osup_vnum "$OS_VER")" -le "$(_osup_vnum "$ver")" ]; then osup_fail "$(osup_dru_reason "$rc" "$ver")"; return 1; fi
    # Код ошибки при выросшем выпуске: апгрейдер упал посреди установки
    # (base-files ставится рано). Довести, и только чистую систему — дальше.
    if [ "$rc" -ne 0 ]; then
        osup_log "ЗАМЕЧАНИЕ: do-release-upgrade вышел с кодом ${rc}, а выпуск уже ${OS_VER} — восстанавливаю до перезагрузки"
        if osup_recover force && { osup_apt update || osup_log "apt-get update: код $?"; osup_apt dist; }; then
            out=$(dpkg --audit 2>/dev/null) || true
        else
            out="x"
        fi
        if [ -n "$out" ]; then
            osup_fail "$(bi "прыжок на ${OS_VER} оборвался (do-release-upgrade, код ${rc}), система недонастроена — сервер не перезагружен; dpkg --audit, ${OSUP_LOG}" "the jump to ${OS_VER} broke off (do-release-upgrade, code ${rc}), the system is not configured — the server was not rebooted; dpkg --audit, ${OSUP_LOG}")"
            return 1
        fi
        osup_log "ЗАМЕЧАНИЕ: после кода ${rc} система доведена, dpkg --audit пуст — продолжаю"
        os_detect
    fi
    osup_step_end "$l"
    osup_step_begin "boot-$OS_VER"
    osup_reboot "$(bi "после прыжка на ${OS_VER}" "after the jump to ${OS_VER}")"
    return $?
}

# ── завершение на 24.04 ─────────────────────────────────────────────────
# Сбой любого пункта — замечание, а не failed: ОС уже обновлена.
osup_finish() {
    _osup_paths
    osup_step_begin fin
    osup_set to "$OS_PRETTY"
    OSU_NOTES=(); OSU_DID=()
    osup_fix_ssh
    osup_fix_lists
    osup_apt update || osup_log "apt-get update: код $?"
    osup_fix_pkgs
    osup_fix_units
    osup_fix_dkms
    osup_fix_docker
    osup_fix_ufw
    if prod_installed gokaskad; then
        local v; v=$(prod_version gokaskad 2>/dev/null) || v=""
        if [ "${v%%.*}" = 3 ]; then osup_note "goKaskad pro|$(bi "после смены ОС запустите gokaskad — он предложит перейти на nftables" "after the OS change run gokaskad — it offers to move to nftables")|goKaskad pro: nftables|gokaskad|warn"
        else osup_note "goKaskad pro|$(bi "после смены ОС проверьте правила и проброс" "after the OS change check the rules and forwarding")|goKaskad pro: $(bi "проверьте проброс" "check forwarding")|gokaskad|warn"; fi
    fi
    osup_step_end fin
    osup_set status done; osup_set finished "$(_osup_now)"; osup_set seen 0; osup_save
    osup_log "=== готово: ${OS_PRETTY}"
    osup_cleanup
    return 0
}
# SSH — первым: потеря SSH — это потеря сервера.
# Сверяются ФАКТИЧЕСКИЕ порты: где SSH слушал до обновления (снимок «до» из
# ss), там должен слушать и после — sshd или systemd на ssh.socket. После
# перезагрузки на 24.04, пока никто не зашёл, sshd не запущен и слушает
# только ssh.socket; настройки тут не судья (на сервере без строки Port
# сверка по ним давала ложное «не слушает 22»). Снимка нет — порты из
# настроек (osup_ssh_cfg_ports).
# Перед сверкой — sshd -t: на 24.04 порт держит ssh.socket, и «слушает» ещё
# не значит «sshd стартует». Настройки не проходят — красное замечание и
# никаких перезапусков: перезапуск с битыми настройками уронил бы SSH.
osup_fix_ssh() {
    local want="" raw now p miss="" u bad
    bad=$(_osup_sshd_test)
    if [ -n "$bad" ]; then
        osup_log "sshd -t: ${bad}"
        osup_note "SSH|$(bi "настройки SSH не проходят проверку: ${bad} — не закрывайте текущую сессию, проверьте /etc/ssh/sshd_config" "the SSH settings fail the check: ${bad} — do not close the current session, check /etc/ssh/sshd_config")|SSH: sshd -t|sshd -t|err"
    fi
    raw=$(cat "$OSUP_BEFORE/ssh" 2>/dev/null) || raw=""
    if [ -z "${raw//[[:space:]]/}" ]; then
        raw=$(osup_ssh_cfg_ports)
        [ -n "${raw//[[:space:]]/}" ] && osup_log "снимка SSH «до» нет — порты из настроек: ${raw% }"
    fi
    for p in $raw; do case "$p" in ''|*[!0-9]*) ;; *) want+="${want:+ }$p" ;; esac; done
    [ -n "$want" ] || return 0
    _osup_miss() { miss=""; now=" $(osup_ssh_ports "$want") "; for p in $want; do case "$now" in *" $p "*) ;; *) miss+="${miss:+ }$p" ;; esac; done; }
    _osup_miss
    [ -z "$miss" ] && { osup_log "SSH слушает: ${want}"; return 0; }
    if [ -n "$bad" ]; then
        u=$(_osup_ssh_unit)
        osup_log "SSH не слушает ${miss} — настройки не проходят sshd -t, ${u} не перезапускаю"
    else
        systemctl daemon-reload >/dev/null 2>&1
        u=$(_osup_ssh_unit)
        osup_log "SSH не слушает ${miss} — перезапускаю ${u}"
        systemctl restart "$u" >/dev/null 2>&1
        sleep "${GOINST_OSUP_SETTLE:-3}"
        _osup_miss
        if [ -z "$miss" ]; then osup_did "$(bi "SSH снова слушает ${want} (перезапущен ${u})" "SSH listens on ${want} again (${u} restarted)")"; return 0; fi
    fi
    osup_note "SSH|$(bi "не слушает порт ${miss} — зайдите через консоль хостера" "does not listen on port ${miss} — log in through the hosting console")|SSH: $(bi "порт" "port") ${miss}|journalctl -u ${u}|err"
}
# sshd -t: пусто — настройки прошли (или sshd на машине нет), иначе первая
# строка ответа. «Missing privilege separation directory» — не ошибка
# настроек: sshd смотрит /run/sshd уже после их разбора, а на 24.04 до
# первого входа каталога нет (его создаёт ssh.service).
_osup_sshd_test() {
    local out rc=0 l
    command -v sshd >/dev/null 2>&1 || return 0
    out=$(LC_ALL=C sshd -t 2>&1) || rc=$?
    [ "$rc" = 0 ] && return 0
    case "$out" in *"Missing privilege separation directory"*) return 0 ;; esac
    l=$(sed -n '/[^[:space:]]/{p;q;}' <<<"$out")
    l="${l//|/ }"; [ "${#l}" -gt 160 ] && l="${l:0:160}…"
    printf '%s' "${l:-$(bi "код ${rc}" "code ${rc}")}"
}
# Какой юнит SSH перезапускать: ssh.socket — только включённый или
# работающий и не замаскированный; иначе ssh.service (sshd.service там, где
# юнит так назван).
_osup_ssh_unit() {
    local l
    l=$(systemctl show -p LoadState ssh.socket 2>/dev/null) || l=""
    if [ "${l#LoadState=}" = loaded ]; then
        case "$(unit_state ssh.socket)" in run|down) printf 'ssh.socket'; return 0 ;; esac
    fi
    if [ "$(unit_state ssh.service)" = none ] && [ "$(unit_state sshd.service)" != none ]; then printf 'sshd.service'
    else printf 'ssh.service'; fi
}
# Списки продуктов: *.list.distUpgrade → .list с noble, если репозиторий его отдаёт.
osup_fix_lists() {
    local l f a txt line url suite okk foreign="" g short
    for f in "$OSUP_SL"/*.distUpgrade; do
        [ -e "$f" ] || continue
        g="${f##*/}"; g="${g%.distUpgrade}"
        case " $OSUP_LISTS " in *" $g "*) ;; *) foreign+="${foreign:+, }$g" ;; esac
    done
    for l in $OSUP_LISTS; do
        f="$OSUP_SL/$l.distUpgrade"; a="$OSUP_SL/$l"; short="${l%.list}"
        [ -e "$f" ] || continue
        if [ "$OSUP_FIX_LISTS" != 1 ]; then
            osup_note "apt|$(bi "источник ${short} выключен обновлением — верните его установщиком продукта" "the ${short} source was disabled by the upgrade — restore it with the product installer")|apt: ${short}|${f}|warn"; continue
        fi
        txt=$(sed -E 's/(^|[[:space:]])(focal|jammy)([-[:space:]]|$)/\1noble\3/g' "$f" 2>/dev/null) || txt=""
        okk=1
        while IFS= read -r line; do
            case "$line" in deb\ *|deb-src\ *) ;; *) continue ;; esac
            line="${line#* }"; line=$(sed -E 's/^\[[^]]*\][[:space:]]*//' <<<"$line")
            url="${line%% *}"; line="${line#* }"; suite="${line%% *}"
            [ -n "$url" ] && [ -n "$suite" ] || continue
            _comp_t 20 curl -sfI -o /dev/null --max-time 20 "${url%/}/dists/${suite}/InRelease" 2>/dev/null \
                || _comp_t 20 curl -sfI -o /dev/null --max-time 20 "${url%/}/dists/${suite}/Release" 2>/dev/null \
                || { okk=0; osup_log "источник ${short}: нет ${suite} в ${url}"; }
        done <<<"$txt"
        if [ "$okk" = 1 ] && [ -n "$txt" ] && printf '%s\n' "$txt" > "$a" 2>/dev/null; then
            chmod 644 "$a" 2>/dev/null; rm -f "$f"
            osup_did "$(bi "источник apt ${short} снова включён — на noble" "apt source ${short} is enabled again — on noble")"; osup_log "источник ${short} включён на noble"
        else
            osup_note "apt|$(bi "источник ${short}: в репозитории нет выпуска для 24.04 — оставлен выключенным" "source ${short}: the repository has no 24.04 release — left disabled")|apt: ${short}|${f}|warn"
        fi
    done
    [ -n "$foreign" ] && osup_note "apt|$(bi "выключены обновлением: ${foreign} — включите сами, если нужны" "disabled by the upgrade: ${foreign} — enable them yourself if needed")|apt: ${foreign}|${OSUP_SL}|warn"
    return 0
}
# Пропавшие пакеты групп компонентов — поставить снова, если есть кандидат.
# Пакеты сторонних репозиториев — не трогать (cloudflare-warp тянет 176
# пакетов): их покажет «Компоненты».
osup_fix_pkgs() {
    local p miss="" third="" want=() inst="" none="" v c
    _osup_pkgs_now
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        _osup_has_pkg "$p" && continue
        case "$p" in
            dnsdist|cloudflare-warp|cloudflared|docker-ce|docker-ce-cli|containerd.io) third+="${third:+ }$p" ;;
            *) want+=("$p") ;;
        esac
    done < "$OSUP_BEFORE/comp"
    if [ "${#want[@]}" -gt 0 ]; then
        p=""
        while IFS= read -r v; do
            case "$v" in
                [!\ ]*:) p="${v%:}"; p="${p%%:*}" ;;
                *Candidate:*) c="${v#*Candidate:}"; c="${c// /}"
                              if [ -n "$p" ] && [ -n "$c" ] && [ "$c" != "(none)" ]; then inst+="${inst:+ }$p"; else none+="${none:+ }$p"; fi ;;
            esac
        done < <(_comp_policy "${want[@]}")
    fi
    if [ -n "$inst" ]; then
        # shellcheck disable=SC2086
        if osup_apt install $inst; then osup_did "$(bi "поставлены снова: ${inst}" "installed again: ${inst}")"
        else
            # Общая транзакция не прошла — по одному: один конфликтный пакет
            # не должен держать libnginx-mod-stream, без которого nginx не стартует.
            local okp="" badp=""
            osup_log "пропавшие пакеты одной транзакцией не встали — ставлю по одному"
            for p in $inst; do
                if osup_apt install "$p"; then okp+="${okp:+ }$p"; else badp+="${badp:+ }$p"; fi
            done
            [ -n "$okp" ] && osup_did "$(bi "поставлены снова: ${okp}" "installed again: ${okp}")"
            [ -n "$badp" ] && osup_note "apt|$(bi "не поставились снова: ${badp}" "did not install again: ${badp}")|apt: ${badp}|${OSUP_LOG}|err"
        fi
    fi
    [ -n "$none" ] && osup_log "пропали без замены в 24.04: ${none}"
    [ -n "$third" ] && osup_note "apt|$(bi "удалены обновлением: ${third} — поставьте их снова в меню продукта" "removed by the upgrade: ${third} — install them again from the product menu")|apt: ${third}|goinstall|warn"
    return 0
}
# Работала до и не работает после — перезапустить и проверить.
osup_fix_units() {
    local u l
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        [ "$(unit_state "$u")" = run ] && continue
        systemctl restart "$u" >/dev/null 2>&1
        sleep "${GOINST_OSUP_SETTLE:-3}"
        if [ "$(unit_state "$u")" = run ]; then osup_did "$(bi "служба ${u} перезапущена" "the ${u} unit restarted")"; osup_log "служба ${u} перезапущена"; continue; fi
        if [ "$u" = nginx ]; then
            # Без конвейера: nginx -t со сломанным конфигом выходит с 1, и под
            # pipefail «|| l=""» стирал найденную строку.
            l=$(nginx -t 2>&1) || true
            l=$(grep -m1 -E 'emerg|error' <<<"$l") || l=""
            osup_note "nginx|$(bi "не запускается" "does not start")${l:+: ${l#nginx: }}|nginx: $(bi "не запускается" "does not start")|nginx -t|err"
        else
            osup_note "${u}|$(bi "служба не запускается после обновления" "the unit does not start after the upgrade")|${u}: $(bi "не работает" "not running")|journalctl -u ${u}|err"
        fi
        osup_log "служба ${u} не поднялась"
    done < "$OSUP_BEFORE/units"
    return 0
}
osup_fix_dkms() {
    local mods k
    mods=$(dkms status 2>/dev/null | sed -n -E 's/^([^,/: ]+).*/\1/p' | sort -u | tr '\n' ' ') || mods=""
    mods="${mods% }"; [ -n "$mods" ] || return 0
    k=$(_osup_kernel)
    if osup_apt install "linux-headers-${k}" && dkms autoinstall >> "$OSUP_LOG" 2>&1; then
        osup_did "$(bi "модуль ${mods} собран под ядро ${k}" "the ${mods} module is built for kernel ${k}")"
    else
        osup_note "DKMS|$(bi "модуль ${mods} не собрался под ядро ${k}" "the ${mods} module did not build for kernel ${k}")|DKMS: ${mods}|dkms status|warn"
    fi
}
osup_fix_docker() {
    local want now c miss t=0 max="${GOINST_OSUP_DOCKER_WAIT:-60}"
    want=$(cat "$OSUP_BEFORE/docker" 2>/dev/null) || want=""
    [ -n "$want" ] || return 0
    while :; do
        now=$'\n'"$(_osup_docker_names)"$'\n'; miss=""
        while IFS= read -r c; do [ -n "$c" ] || continue; case "$now" in *$'\n'"$c"$'\n'*) ;; *) miss+="${miss:+ }$c" ;; esac; done <<<"$want"
        [ -z "$miss" ] && break
        [ "$t" -ge "$max" ] && break
        sleep 5; t=$(( t + 5 ))
    done
    if [ -n "$miss" ]; then osup_note "Docker|$(bi "не поднялись контейнеры: ${miss}" "containers did not come back: ${miss}")|Docker: ${miss}|docker ps -a|err"
    else osup_did "$(bi "контейнеры на месте" "the containers are back")"; fi
}
osup_fix_ufw() {
    [ "$(cat "$OSUP_BEFORE/ufw" 2>/dev/null)" = 1 ] || return 0
    _osup_pkgs_now
    _osup_has_pkg ufw && return 0
    osup_note "ufw|$(bi "удалён обновлением: на 24.04 он несовместим с iptables-persistent. Правила из /etc/iptables/rules.v4 загружаются при старте" "removed by the upgrade: on 24.04 it conflicts with iptables-persistent. The rules in /etc/iptables/rules.v4 load at boot")|$(bi "ufw удалён" "ufw removed")|iptables -S|warn"
}

# ── показ: модель, замечания, тексты ────────────────────────────────────
# osup_model → UD_OSUP (can|cont|run|fail|done или пусто), UD_OSUPLBL,
# UD_OSUPWHY (зачем — для карточки).
osup_model() {
    local id names=""
    UD_OSUP=""; UD_OSUPLBL=""; UD_OSUPWHY=""; OSUP_VIRT=""
    if osup_load; then
        case "${OSU[status]:-}" in
            running) UD_OSUP=run ;;
            failed)  UD_OSUP=fail ;;
            done)    [ "${OSU[seen]:-0}" = 1 ] || UD_OSUP=done ;;
        esac
    fi
    if [ -z "$UD_OSUP" ] && osup_applicable; then
        if osup_container; then UD_OSUP=cont; else UD_OSUP=can; fi
    fi
    case "$UD_OSUP" in
        can|cont) UD_OSUPLBL="Ubuntu ${OS_VER} → ${OSUP_TARGET}"
                  for id in govless gotelegram godns; do
                      prod_installed "$id" && continue
                      case $'\n'"$(prod_os_check "$id" 2>/dev/null)" in *$'\n'must\|*) names+="${names:+, }$(prod_name "$id")" ;; esac
                  done
                  if [ -n "$names" ]; then ut "${names} ставятся только на новой Ubuntu" "${names} install only on a newer Ubuntu"
                  else ut "поддержка Ubuntu 24.04 — до 2029 года" "Ubuntu 24.04 is supported until 2029"; fi
                  UD_OSUPWHY="$UI_TX" ;;
        run)  osup_progress; ut "Ubuntu: обновление, шаг ${OSUP_N} из ${OSUP_M}" "Ubuntu: upgrading, step ${OSUP_N} of ${OSUP_M}"; UD_OSUPLBL="$UI_TX" ;;
        fail) ut "Ubuntu: обновление прервано" "Ubuntu: upgrade interrupted"; UD_OSUPLBL="$UI_TX" ;;
        done) ut "Ubuntu ${OSUP_TARGET}: итог обновления" "Ubuntu ${OSUP_TARGET}: upgrade result"; UD_OSUPLBL="$UI_TX" ;;
    esac
    return 0
}
# Строки для UD_PROB (меню и сводка при входе) → OSUP_PROBS.
osup_probs() {
    local d
    OSUP_PROBS=()
    osup_load || return 0
    case "${OSU[status]:-}" in
        running) osup_progress; osup_dur $(( $(_osup_now) - OSUP_CURT ))
                 local a="$UI_TX"
                 ut "обновляется до ${OSUP_TARGET}: шаг ${OSUP_N} из ${OSUP_M}, идёт ${a}" "upgrading to ${OSUP_TARGET}: step ${OSUP_N} of ${OSUP_M}, running ${a}"; d="$UI_TX"
                 ut "Ubuntu → ${OSUP_TARGET}: шаг ${OSUP_N}/${OSUP_M}" "Ubuntu → ${OSUP_TARGET}: step ${OSUP_N}/${OSUP_M}"
                 OSUP_PROBS+=("Ubuntu|${d}|${UI_TX}|goinstall|warn") ;;
        failed)  ut "обновление до ${OSUP_TARGET} прервано: ${OSU[msg]:-?}" "the upgrade to ${OSUP_TARGET} was interrupted: ${OSU[msg]:-?}"; d="$UI_TX"
                 ut "Ubuntu: обновление прервано" "Ubuntu: upgrade interrupted"
                 OSUP_PROBS+=("Ubuntu|${d//|/ }|${UI_TX}|goinstall|err") ;;
        done)    [ "${OSU[seen]:-0}" = 1 ] && return 0
                 osup_dur $(( ${OSU[finished]:-0} - ${OSU[started]:-0} )); local t="$UI_TX" to="${OSU[to]:-Ubuntu ${OSUP_TARGET}}"
                 ut "обновлена до ${to#Ubuntu } за ${t}" "upgraded to ${to#Ubuntu } in ${t}"; d="$UI_TX"
                 ut "Ubuntu ${OSUP_TARGET}: готово" "Ubuntu ${OSUP_TARGET}: done"
                 OSUP_PROBS+=("Ubuntu|${d}|${UI_TX}|goinstall|ok" ${OSU_NOTES[@]+"${OSU_NOTES[@]}"}) ;;
    esac
    return 0
}
osup_mark_seen() {
    osup_load || return 0; [ "${OSU[status]:-}" = done ] || return 0
    # Итог просмотрен — временный скрипт входа больше не нужен.
    rm -f "$OSUP_HOOK" 2>/dev/null
    [ "${OSU[seen]:-0}" = 1 ] && return 0; osup_set seen 1; osup_save
}
# «Обновлять не буду»: отметка «прервано» уходит, журнал остаётся. Состояние
# — в state.failed-<время> (разобраться потом), служба и скрипт входа снимаются.
osup_dismiss() {
    local t
    osup_load || return 0
    [ "${OSU[status]:-}" = failed ] || return 1
    t=$(printf '%(%Y%m%d-%H%M%S)T' -1)
    mv -f "$OSUP_STATE" "$OSUP_DIR/state.failed-$t" 2>/dev/null || return 1
    rm -f "$OSUP_HOOK" 2>/dev/null
    osup_cleanup
    osup_log "отметка «прервано» снята — обновлять не буду (state.failed-${t})"
    OSU=(); OSU_NOTES=(); OSU_DID=()
    return 0
}
# Временный скрипт входа: ход обновления виден при входе по SSH и тогда,
# когда сводка при входе выключена. Только root, только терминал,
# ~/.hushlogin уважается; при включённой сводке молчит — ход покажет она.
# Команда — по абсолютному пути: PATH входа бывает без /usr/local/bin.
osup_hook_text() {
    local b; b=$(printf '%q' "$GOINST_BIN")
    cat <<HOOK
# goInstaller: ход обновления Ubuntu при входе. Временный — уберётся сам.
if [ -t 0 ] && [ -t 1 ] && [ "\$(id -u)" = 0 ] && [ ! -e "\$HOME/.hushlogin" ] && [ -x ${b} ]; then
    ${b} --os-upgrade status --short 2>/dev/null
fi
HOOK
}
osup_hook_write() {
    _osup_paths
    mkdir -p "$(dirname "$OSUP_HOOK")" 2>/dev/null || return 1
    osup_hook_text > "$OSUP_HOOK" 2>/dev/null || return 1
    chmod 644 "$OSUP_HOOK" 2>/dev/null || true
}
# Одна-две строки хода для входа по SSH — без сети, из состояния.
osup_short() {
    local p n d s g c
    _osup_paths
    if ! osup_load || { [ "${OSU[status]:-}" = done ] && [ "${OSU[seen]:-0}" = 1 ]; }; then rm -f "$OSUP_HOOK" 2>/dev/null; return 0; fi
    # Сводка при входе включена и записана — ход покажет она.
    summary_enabled && [ -e "$SUM_HOOK" ] && [ -r "$SUM_FILE" ] && return 0
    osup_probs
    [ "${#OSUP_PROBS[@]}" -gt 0 ] || return 0
    IFS='|' read -r n d s c g <<<"${OSUP_PROBS[0]}"
    case "$g" in err) p="${RED}✗${NC}" ;; ok) p="${GREEN}✓${NC}" ;; *) p="${YELLOW}!${NC}" ;; esac
    echo -e "  ${p} goInstaller · Ubuntu: ${d} ${DIM}→ goinstall${NC}"
    if [ "${OSU[status]:-}" = running ] && osup_stall; then echo -e "  ${YELLOW}!${NC} ${OSUP_STALLTX}"; fi
    return 0
}
# Признак зависания: шаг идёт дольше часа, а журнал не растёт 20 минут.
# Ничего не убиваем — только говорим. → OSUP_STALLTX; rc 1 — не похоже.
_osup_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
osup_stall() {
    local now m t f="" lf main="${GOINST_FS_ROOT:-}/var/log/dist-upgrade/main.log"
    OSUP_STALLTX=""
    osup_progress
    now=$(_osup_now)
    [ $(( now - OSUP_CURT )) -ge "${GOINST_OSUP_STALL_STEP:-3600}" ] || return 1
    m=0
    for lf in "$OSUP_LOG" "$main"; do
        t=$(_osup_mtime "$lf") || t=""
        case "$t" in ''|*[!0-9]*) continue ;; esac
        [ "$t" -gt "$m" ] && m=$t
    done
    [ "$m" -gt 0 ] || return 1
    [ $(( now - m )) -ge "${GOINST_OSUP_STALL_LOG:-1200}" ] || return 1
    case "$OSUP_CUR" in rel-*) f="/var/log/dist-upgrade/main.log" ;; *) f="$OSUP_LOG" ;; esac
    OSUP_STALLTX=$(bi "журнал не растёт $(( (now - m) / 60 )) мин — возможно, зависло: ${f}" "the log has not grown for $(( (now - m) / 60 )) min — it may be stuck: ${f}")
    return 0
}

# Абзац для нумерованного режима и CLI — перенос по словам под ширину окна
# с отступом в два пробела. Иначе терминал рвёт строку посреди слова, а это
# экран предупреждения о бэкапе, его должны прочитать целиком. Ширина — та же
# menu_cols, что у меню: без TERM и с мусором в COLUMNS она даёт 80.
say_par() {  # say_par <текст>
    local w line="" word
    local -a words=()
    w=$(( $(menu_cols) - 4 )); [ "$w" -lt 30 ] && w=30
    read -r -a words <<<"$1"
    for word in ${words[@]+"${words[@]}"}; do
        if [ -z "$line" ]; then line="$word"
        elif [ $(( $(str_len "$line") + 1 + $(str_len "$word") )) -le "$w" ]; then line+=" $word"
        else echo -e "  ${line}" >&2; line="$word"; fi
    done
    [ -n "$line" ] && echo -e "  ${line}" >&2
    return 0
}
# Предупреждение текстом (CLI и нумерованное меню).
osup_print_warning() {
    local k t
    if [ "$OS_VER" = 20.04 ]; then
        say "${OS_PRETTY} → 22.04 → ${OSUP_TARGET} LTS"
        say_par "$(bi "Два шага штатной программой Ubuntu, 20–60 минут, перезагрузки 2–4." "Two steps with Ubuntu's own upgrader, 20–60 minutes, 2–4 reboots.")"
    else
        say "${OS_PRETTY} → ${OSUP_TARGET} LTS"
        say_par "$(bi "Один шаг штатной программой Ubuntu, 15–40 минут, перезагрузки 1–2." "One step with Ubuntu's own upgrader, 15–40 minutes, 1–2 reboots.")"
    fi
    say_par "$(bi "SSH будет отключаться, на последнем шаге — до 10 минут. Это нормально, обновление идёт само." "SSH drops out, on the last step for up to 10 minutes. That is normal, the upgrade goes on by itself.")"
    echo "" >&2
    echo -e "  ${YELLOW}${BOLD}! $(bi "Сначала бэкап" "Backup first")${NC}" >&2
    say_par "$(bi "Сделайте снимок (бэкап) сервера в панели хостера. Если обновление прервётся, вернуть сервер можно только из снимка." "Take a snapshot (backup) of the server in the hosting panel. If the upgrade breaks off, the server can only be restored from the snapshot.")"
    echo "" >&2
    for k in "${OSUP_CHK[@]}"; do
        t="${k#*|}"
        case "$k" in
            bad\|*) err "$t" ;; warn\|*) warn "$t" ;; ok\|*) ok "$t" ;;
            do\|*) say "$(bi "goInstaller сам" "goInstaller will"): $t" ;;
            *) echo -e "  ${DIM}·${NC}  $t" >&2 ;;
        esac
    done
}
# Ход и итог текстом.
osup_print_state() {
    local i l g d p
    osup_load || { say "$(bi "Обновления Ubuntu не было." "No Ubuntu upgrade so far.")"; return 0; }
    osup_progress
    case "${OSU[status]:-}" in
        running) say "$(bi "Обновление Ubuntu идёт: шаг ${OSUP_N} из ${OSUP_M}." "The Ubuntu upgrade is running: step ${OSUP_N} of ${OSUP_M}.")"
                 osup_stall && warn "$OSUP_STALLTX" ;;
        failed)  err "$(bi "Обновление Ubuntu прервано:" "The Ubuntu upgrade was interrupted:") ${OSU[msg]:-?}" ;;
        done)    osup_dur $(( ${OSU[finished]:-0} - ${OSU[started]:-0} )); ok "$(bi "Ubuntu обновлена:" "Ubuntu is upgraded:") ${OSU[to]:-${OSUP_TARGET}}, ${UI_TX}" ;;
    esac
    for ((i = 0; i < ${#OSUP_PLAN[@]}; i++)); do
        l="${OSUP_PLAN[$i]}"; osup_step_title "$l"
        if osup_step_done "$l"; then g="✓"; elif [ "$l" = "$OSUP_CUR" ]; then g="●"; else g="○"; fi
        printf '      %s %s\n' "$g" "$UI_TX" >&2
    done
    for d in ${OSU_DID[@]+"${OSU_DID[@]}"}; do echo -e "  ${DIM}·${NC}  $d" >&2; done
    for p in ${OSU_NOTES[@]+"${OSU_NOTES[@]}"}; do
        IFS='|' read -r i l g d _ <<<"$p"
        case "$p" in *'|err') err "${i}: ${l} → ${d}" ;; *) warn "${i}: ${l} → ${d}" ;; esac
    done
    say "$(bi "Журнал:" "Log:") ${OSUP_LOG}"
    [ "${OSU[status]:-}" = failed ] && say "$(bi "Обновлять не будете — снять отметку: goinstall --os-upgrade dismiss" "Not upgrading — clear the mark: goinstall --os-upgrade dismiss")"
    return 0
}
# Вопрос и запуск (CLI и нумерованное меню). yes=1 — без вопроса.
osup_flow() {
    local yes="${1:-}"
    print_header "$(bi "Обновление Ubuntu до ${OSUP_TARGET}" "Upgrade Ubuntu to ${OSUP_TARGET}")"
    say "$(bi "Проверяю сервер…" "Checking the server…")"
    osup_check "${GOINST_OSUP_CHECK_WAIT:-60}"
    osup_print_warning
    if [ "$OSUP_BAD" -gt 0 ]; then err "$(bi "Запуск невозможен — причины выше." "Cannot start — see the reasons above.")"; return 1; fi
    if [ -z "$yes" ]; then
        confirm "$(bi "Бэкап сделан — обновить до ${OSUP_TARGET}?" "The backup is done — upgrade to ${OSUP_TARGET}?")" n || { say "$(bi "Отменено, ничего не менялось." "Cancelled, nothing changed.")"; return 2; }
    fi
    # Команда goinstall — до запуска, как в меню и --install: из
    # `bash go-installer.sh --os-upgrade --yes` её иначе не было бы, и ни хода
    # при входе, ни обещанного «ход — goinstall».
    self_install
    osup_start || { err "${OSUP_ERR}"; return 1; }
    if [ -x "$GOINST_BIN" ]; then
        ok "$(bi "Обновление запущено службой ${OSUP_UNIT}. Сервер перезагрузится сам; ход — goinstall или goinstall --os-upgrade status." "The upgrade is started by the ${OSUP_UNIT} unit. The server reboots by itself; progress — goinstall or goinstall --os-upgrade status.")"
    else
        ok "$(bi "Обновление запущено службой ${OSUP_UNIT}. Сервер перезагрузится сам; ход — в журнале ${OSUP_LOG}." "The upgrade is started by the ${OSUP_UNIT} unit. The server reboots by itself; progress — in the log ${OSUP_LOG}.")"
    fi
    return 0
}
# goinstall --os-upgrade [--yes] | status. Коды status: 0 — нет или готово,
# 1 — прервано, 3 — идёт. Запуск: 0 — запущено, 1 — отказ, 2 — «нет», 3 — уже
# идёт, 4 — без терминала и без --yes. У --uninstall и --components update
# «без терминала» — 3, но здесь 3 уже значит «идёт» (и у status тоже):
# скрипт, ждущий «идёт», принял бы отказ за запущенное обновление.
osup_cli() {
    local yes="" a st="" short="" dis=""
    for a in "$@"; do
        case "$a" in
            status) st=1 ;;
            --short) short=1 ;;
            dismiss) dis=1 ;;
            --yes|-y) yes=1 ;;
            *) usage; return 64 ;;
        esac
    done
    if [ -n "$short" ] && [ -z "$st" ]; then usage; return 64; fi
    if [ -n "$st" ]; then
        [ -n "$short" ] && { osup_short; return 0; }
        osup_print_state
        osup_load || return 0
        case "${OSU[status]:-}" in running) return 3 ;; failed) return 1 ;; *) osup_mark_seen; return 0 ;; esac
    fi
    if [ -n "$dis" ]; then
        osup_busy_refuse && return 1
        if osup_dismiss; then ok "$(bi "Отметка «прервано» снята. Журнал остался: ${OSUP_LOG}" "The “interrupted” mark is cleared. The log stays: ${OSUP_LOG}")"; return 0; fi
        err "$(bi "Снимать нечего: обновление не прервано." "Nothing to clear: the upgrade is not interrupted.")"; return 1
    fi
    if osup_load; then
        case "${OSU[status]:-}" in
            running) osup_print_state; return 3 ;;
            done) if ! osup_applicable; then osup_print_state; osup_mark_seen; return 0; fi ;;
        esac
    fi
    if ! osup_applicable && [ "${OSU[status]:-}" != failed ]; then
        err "$(bi "Обновление — только с Ubuntu 20.04 и 22.04 (здесь ${OS_PRETTY:-?})." "The upgrade is only from Ubuntu 20.04 and 22.04 (this is ${OS_PRETTY:-?}).")"; return 1
    fi
    if [ -z "$yes" ] && [ ! -t 0 ]; then
        err "$(bi "Без терминала спросить некого: goinstall --os-upgrade --yes" "No terminal to ask: goinstall --os-upgrade --yes")"; return 4
    fi
    [ "${OSU[status]:-}" = failed ] && osup_print_state
    osup_flow "$yes"
}
# Нумерованное меню: пункт «o».
osup_menu() {
    local c
    if osup_load && [ "${OSU[status]:-}" = failed ]; then
        # Прервано: снова (пока есть попытки) или «обновлять не буду».
        osup_print_state
        echo "" >&2
        [ "$(osup_num attempt)" -lt 3 ] && echo -e "  ${CYAN}1)${NC} $(bi "Попробовать снова" "Try again")" >&2
        echo -e "  ${CYAN}2)${NC} $(bi "Убрать отметку — обновлять не буду" "Clear the mark — I will not upgrade")" >&2
        echo -e "  ${CYAN}0)${NC} $(bi "Назад" "Back")" >&2
        read_line c || return 0
        case "$c" in
            1) [ "$(osup_num attempt)" -lt 3 ] || return 0; osup_flow ;;
            2) osup_dismiss && ok "$(bi "Отметка снята. Журнал остался: ${OSUP_LOG}" "The mark is cleared. The log stays: ${OSUP_LOG}")" ;;
            *) return 0 ;;
        esac
    elif osup_load && { [ "${OSU[status]:-}" = running ] || ! osup_applicable; }; then
        osup_print_state; osup_mark_seen
    else
        osup_flow
    fi
    echo -ne "  $(bi "Нажмите Enter, чтобы вернуться" "Press Enter to return") " >&2; read -r || true
}

# ── точка входа ─────────────────────────────────────────────────────────
# ═══ Интерфейс «Аркада» ════════════════════════════════════════════════
# Макет — пакет Claude Design в design/handoff: прототип, экраны построчно,
# цвета. Правила там же, в design/README.md, и они сильнее пакета.
#
# Экран — массив строк UI_BODY. Строка — сегменты «токен␟текст␞»: токен —
# роль цвета (title, muted, grad…), суффикс «+sel» — выделенная строка.
# Одна и та же строка печатается тремя способами: в цвете (truecolor, 256,
# 16 или без цвета), в ASCII и дампом по клеткам — им тест сверяет экран с
# эталоном клетка в клетку. Ширина считается в символах, поэтому локаль —
# UTF-8 (ui_locale_fix); без неё bash считает байты, и рамки разъезжаются.

UI_US=$'\x1f'; UI_RS=$'\x1e'
UI_COLOR="true"; UI_BG="dark"; UI_ASCII=0
UI_C=80; UI_R=24; UI_COLS=80; UI_LINES=24
UI_BODY=(); UI_INFO=""; UI_KEYS=""
UI_GRADN=0

# Токены «Аркады»: снято с design/handoff/spec/tokens.json.
# имя|тёмный|светлый|256 тёмный|256 светлый|ANSI-16|без цвета|жирный|текст выделения на тёмном
_UI_TOKENS='title|#ffd23f|#0038b8|221|25|33;1|1|1|-
text|#e6e9f5|#1a1f3a|255|235|39|-|0|-
muted|#8e96b8|#565e80|103|60|90|2|0|-
rule|#3d6bff|#2f5bdc|63|26|34|2|0|-
name|#ffffff|#0d1230|231|234|39;1|-|0|-
cursor|#34d2ff|#0068a8|81|25|36;1|1|1|-
key|#34d2ff|#0068a8|81|25|36|1|0|-
ok|#3ee07a|#16803e|78|29|32|-|0|-
update|#ffb02e|#9a5a00|214|94|33;1|1|1|-
new|#ff5fd2|#b0158a|206|126|35;1|1|1|-
warn|#ff9a3c|#a44a00|209|130|33|1|0|-
err|#ff4d5e|#c0182e|203|124|31;1|1|1|-
grad|#2f6bff:#34d2ff|#1d4ed8:#0086b8|27:81|26:31|34;1|1|0|-
sel|#1d3aa8|#dfe7ff|25|189|7|7|0|#ffffff
logo0|#fff4b0|#f0a000|229|214|33;1|1|1|-
logo1|#ffd23f|#e07800|221|172|33;1|1|1|-
logo2|#ff9a1f|#d04800|208|166|31;1|1|1|-
logo3|#ff5a1f|#b02400|202|124|31;1|1|1|-
shade|#9c2433|#5a1020|125|52|31;2|2|0|-
shadow|#343a66|#c3c9e6|238|252|34;2|2|0|-
in|#1fb6ff|#0068a8|39|25|36|-|0|-
out|#9fe3ff|#4a97c9|153|68|96|-|0|-'

# ASCII-замены: design/handoff/spec/ascii-fallback.json, у каждого значка
# статуса своя буква (✓ v, ✚ +, ◆ ~).
# Полосы и сетка статистики защиты — design/shield/handoff-stats/.../spec/ascii-fallback-shield.json;
# «×» (всплеск) и «№» (топ) там не названы, а в экранах есть — x и #.
_UI_ASC='─ - ━ - │ | ┌ + ┐ + └ + ┘ + ├ + ┤ + ┬ + ┴ + ┼ + ╭ + ╮ + ╰ + ╯ + ═ = ║ | ╔ + ╗ + ╚ + ╝ + █ # ▓ # ▒ = ░ . ▀ " ▄ _ ▌ [ ▐ ] ▏ = ▎ = ▍ = ▋ = ▊ = ▉ = ▕ ] ● * ○ o ▲ ^ ▼ V ▸ > ◆ ~ ✓ v ✗ x ✚ + · . → > ← < ↑ ^ ↓ v … . — - « " » " – - ⠋ | ⠙ / ⠹ - ⠸ \ ⠼ | ⠴ / ⠦ - ⠧ \ ⠇ | ⠏ / ▁ _ ▂ _ ▃ - ▅ = ▇ # ┊ : × x № #'

# Локаль сессии не установлена (SSH принёс ru_RU.UTF-8, а на сервере её
# нет) — bash считает байты вместо символов, и кириллица рвёт рамки.
# C.UTF-8 есть на любой современной Ubuntu и Debian; нет и её — ASCII.
ui_locale_fix() {
    local cm la
    if [ -n "${GOINST_ASCII:-}" ]; then UI_ASCII=1; return 0; fi
    cm=$(locale charmap 2>/dev/null) || cm=""
    case "$cm" in UTF-8|utf8|UTF8) UI_ASCII=0; return 0 ;; esac
    # Список — в переменную, не в `| grep -q`: под pipefail grep закрывает
    # канал на первом совпадении, locale -a ловит SIGPIPE, и «C.UTF-8 нет»
    # выходило там, где она есть (на macOS — каждый раз).
    la=$(locale -a 2>/dev/null) || la=""
    if grep -qiE '^c\.utf-?8$' <<<"$la"; then
        export LC_ALL=C.UTF-8
        UI_ASCII=0; return 0
    fi
    UI_ASCII=1
    return 0
}

# Режим цвета и фон — по правилам пакета (README, «Выбор режима»).
ui_detect() {
    if [ -n "${GOINST_COLOR:-}" ]; then UI_COLOR="$GOINST_COLOR"
    elif [ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = dumb ]; then UI_COLOR=none
    elif [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then UI_COLOR=true
    else case "${TERM:-}" in *256color*) UI_COLOR=256 ;; *) UI_COLOR=16 ;; esac
    fi
    case "${GOINST_BG:-}" in
        light|dark) UI_BG="$GOINST_BG" ;;
        *) case "${COLORFGBG:-}" in
               *\;15|*\;7) UI_BG=light ;;
               *) if [ "${TERM_PROGRAM:-}" = Apple_Terminal ]; then UI_BG=light; else UI_BG=dark; fi ;;
           esac ;;
    esac
    ui_locale_fix
    ui_size
    ui_tokens
}

# Размер окна → раскладка: от 80 колонок — две панели, 46–79 — один столбец,
# меньше 46 × 24 — экран «окно слишком мало».
#
# На большом окне холст 80×24 стоял в левом верхнем углу, и меню казалось
# мелким и брошенным с краю (заказчик, 5.10). Три размера, F2 по кругу:
#   full    — рамки по ширине окна, не шире 160, по центру. Высота остаётся
#             24: содержимое короткое, и высокие окна выходили пустыми
#             коробками — проверено отрисовкой на 130×34;
#   center  — прежние 80×24 посреди окна;
#   compact — прежние 80×24 в углу.
# Шрифт скрипт не меняет: это настройка терминала.
UI_SIZES="full center compact"
ui_size_file() { printf '%s' "${GOINST_UI_SIZE_FILE:-${GOINST_DIR}/.ui-size}"; }
ui_size_mode() {
    local m="${GOINST_UI_SIZE:-}"
    [ -n "$m" ] || m=$(head -1 "$(ui_size_file)" 2>/dev/null) || m=""
    case "$m" in full|center|compact) printf '%s' "$m" ;; *) printf 'full' ;; esac
}
ui_size_next() {  # следующий размер по кругу, запомнить
    local cur n
    cur=$(ui_size_mode)
    case "$cur" in full) n=center ;; center) n=compact ;; *) n=full ;; esac
    GOINST_UI_SIZE="$n"
    mkdir -p "$(dirname "$(ui_size_file)")" 2>/dev/null && printf '%s\n' "$n" > "$(ui_size_file)" 2>/dev/null
    return 0
}
ui_size() {
    local c l m
    c="${GOINST_UI_COLS:-$(tput cols 2>/dev/null)}"; l="${GOINST_UI_LINES:-$(tput lines 2>/dev/null)}"
    case "$c" in ''|*[!0-9]*) c=80 ;; esac
    case "$l" in ''|*[!0-9]*) l=24 ;; esac
    UI_COLS="$c"; UI_LINES="$l"; UI_PADL=0; UI_PADT=0
    if [ "$c" -lt 46 ] || [ "$l" -lt 24 ]; then UI_C=40; UI_R=16
    elif [ "$c" -lt 80 ]; then UI_C=46; UI_R=24
    else UI_C=80; UI_R=24; fi
    [ "$UI_C" = 80 ] || return 0
    m=$(ui_size_mode)
    if [ "$m" = full ]; then
        UI_C=$(( c > 160 ? 160 : c ))
    fi
    if [ "$m" != compact ]; then
        UI_PADL=$(( (c - UI_C) / 2 )); UI_PADT=$(( (l - UI_R) / 2 ))
    fi
    return 0
}

_ui_rgb() { printf -v "$1" '%d;%d;%d' "0x${2:1:2}" "0x${2:3:2}" "0x${2:5:2}"; }
# Ближайший цвет палитры 256: куб 16–231 или серая шкала 232–255.
_ui_q6() { if [ "$1" -lt 48 ]; then UI_Q=0; elif [ "$1" -lt 115 ]; then UI_Q=1; else UI_Q=$(( ($1 - 35) / 40 )); fi; }
_ui_to256() {
    local r="$2" g="$3" b="$4" qr qg qb cr cg cb gi gv dc dg
    _ui_q6 "$r"; qr=$UI_Q; _ui_q6 "$g"; qg=$UI_Q; _ui_q6 "$b"; qb=$UI_Q
    local cube=(0 95 135 175 215 255)
    cr=${cube[$qr]}; cg=${cube[$qg]}; cb=${cube[$qb]}
    gi=$(( ( (r + g + b) / 3 - 8 + 5 ) / 10 )); [ "$gi" -lt 0 ] && gi=0; [ "$gi" -gt 23 ] && gi=23
    gv=$(( 8 + 10 * gi ))
    dc=$(( (r-cr)*(r-cr) + (g-cg)*(g-cg) + (b-cb)*(b-cb) ))
    dg=$(( (r-gv)*(r-gv) + (g-gv)*(g-gv) + (b-gv)*(b-gv) ))
    if [ "$dg" -lt "$dc" ]; then printf -v "$1" '%s' "$(( 232 + gi ))"
    else printf -v "$1" '%s' "$(( 16 + 36*qr + 6*qg + qb ))"; fi
}

# Последовательности цвета для каждого токена в текущем режиме и фоне.
ui_tokens() {
    declare -gA UI_SGR=() UI_SGRSEL=()
    UI_GRAD=(); UI_GRADN=0
    local name td tl nd nl a16 nc bold selfg fg n256 rgb code codes sel_bg="" sel_fg="" sel256 hexs a b c r g bb n
    local line
    # Фон и текст выделенной строки.
    while IFS='|' read -r name td tl nd nl a16 nc bold selfg; do
        [ "$name" = sel ] || continue
        if [ "$UI_BG" = dark ]; then hexs="$td"; sel256="$nd"; else hexs="$tl"; sel256="$nl"; fi
        _ui_rgb rgb "$hexs"
        case "$UI_COLOR" in
            true) sel_bg="48;2;$rgb" ;;
            256) sel_bg="48;5;$sel256" ;;
        esac
        if [ "$UI_BG" = dark ] && [ "$selfg" != "-" ]; then sel_fg="$selfg"; fi
    done <<<"$_UI_TOKENS"
    while IFS='|' read -r name td tl nd nl a16 nc bold selfg; do
        [ -n "$name" ] || continue
        if [ "$UI_BG" = dark ]; then fg="$td"; n256="$nd"; else fg="$tl"; n256="$nl"; fi
        codes=""
        case "$UI_COLOR" in
            none)
                [ "$nc" != "-" ] && codes="$nc"
                UI_SGR[$name]=$'\033[0'"${codes:+;$codes}m"
                UI_SGRSEL[$name]=$'\033[0'"${codes:+;$codes};7m" ;;
            16)
                UI_SGR[$name]=$'\033[0;'"${a16}m"
                UI_SGRSEL[$name]=$'\033[0;'"${a16};7m" ;;
            256|true)
                [ "$bold" = 1 ] && codes="1;"
                if [ "$name" = grad ]; then
                    UI_SGR[$name]=$'\033[0;'"${codes}38;5;${n256%%:*}m"
                else
                    if [ "$UI_COLOR" = true ]; then _ui_rgb rgb "$fg"; code="38;2;$rgb"
                    else code="38;5;$n256"; fi
                    UI_SGR[$name]=$'\033[0;'"${codes}${code}m"
                    if [ -n "$sel_fg" ]; then
                        if [ "$UI_COLOR" = true ]; then _ui_rgb rgb "$sel_fg"; code="38;2;$rgb"; else code="38;5;231"; fi
                    fi
                    UI_SGRSEL[$name]=$'\033[0;'"${codes}${code}${sel_bg:+;$sel_bg}m"
                fi ;;
        esac
    done <<<"$_UI_TOKENS"
    # Перелив рамки: цвет клетки по номеру колонки, от первого цвета ко второму.
    if [ "$UI_COLOR" = true ] || [ "$UI_COLOR" = 256 ]; then
        while IFS='|' read -r name td tl nd nl a16 nc bold selfg; do
            [ "$name" = grad ] || continue
            if [ "$UI_BG" = dark ]; then hexs="$td"; else hexs="$tl"; fi
            local ha="${hexs%%:*}" hb="${hexs##*:}" ar ag ab br bg2 bb2 i den
            ar=$((16#${ha:1:2})); ag=$((16#${ha:3:2})); ab=$((16#${ha:5:2}))
            br=$((16#${hb:1:2})); bg2=$((16#${hb:3:2})); bb2=$((16#${hb:5:2}))
            den=$(( UI_C - 1 )); [ "$den" -lt 1 ] && den=1
            for ((i = 0; i < UI_C; i++)); do
                r=$(( ar + ( (br - ar) * i * 2 + den ) / (2 * den) ))
                g=$(( ag + ( (bg2 - ag) * i * 2 + den ) / (2 * den) ))
                bb=$(( ab + ( (bb2 - ab) * i * 2 + den ) / (2 * den) ))
                if [ "$UI_COLOR" = true ]; then UI_GRAD[$i]=$'\033[0;'"38;2;$r;$g;${bb}m"
                else _ui_to256 n "$r" "$g" "$bb"; UI_GRAD[$i]=$'\033[0;'"38;5;${n}m"; fi
            done
            UI_GRADN="$UI_C"
        done <<<"$_UI_TOKENS"
    fi
    declare -gA UI_ASC=()
    local k v
    set -f
    # shellcheck disable=SC2086
    set -- $_UI_ASC
    set +f
    while [ $# -ge 2 ]; do UI_ASC["$1"]="$2"; shift 2; done
    return 0
}

# ── сегменты ───────────────────────────────────────────────────────────
# ui_len <сегменты> → UI_N — длина строки в клетках.
ui_len() {
    local s="$1" t n=0
    while [ -n "$s" ]; do
        t="${s%%"${UI_RS}"*}"; s="${s#*"${UI_RS}"}"
        t="${t#*"${UI_US}"}"; n=$(( n + ${#t} ))
    done
    UI_N=$n
}
# ui_padr <текст> <ширина> → UI_P: дополнить пробелами или обрезать с «…».
ui_padr() {
    local s="$1" n="$2"
    if [ "${#s}" -gt "$n" ]; then UI_P="${s:0:$(( n - 1 ))}…"
    else printf -v UI_P '%s%*s' "$s" "$(( n - ${#s} ))" ''; fi
}
# ui_rep <символ> <сколько> → UI_P
ui_rep() { local i s=""; for ((i = 0; i < $2; i++)); do s+="$1"; done; UI_P="$s"; }
# ui_fit <сегменты> <ширина> → UI_FIT и UI_FITN: не шире W, хвост — «…».
ui_fit() {
    local s="$1" w="$2" seg tok txt used=0 out="" l
    while [ -n "$s" ]; do
        [ "$used" -ge "$w" ] && break
        seg="${s%%"${UI_RS}"*}"; s="${s#*"${UI_RS}"}"
        tok="${seg%%"${UI_US}"*}"; txt="${seg#*"${UI_US}"}"
        l=${#txt}
        if [ $(( used + l )) -gt "$w" ]; then txt="${txt:0:$(( w - used - 1 ))}…"; l=${#txt}; fi
        out+="$tok${UI_US}$txt${UI_RS}"; used=$(( used + l ))
    done
    UI_FIT="$out"; UI_FITN="$used"
}
# ui_sel <сегменты> → UI_P: те же сегменты, выделенные.
ui_sel() {
    local s="$1" seg tok out=""
    while [ -n "$s" ]; do
        seg="${s%%"${UI_RS}"*}"; s="${s#*"${UI_RS}"}"
        tok="${seg%%"${UI_US}"*}"
        case "$tok" in *+sel) ;; *) tok="$tok+sel" ;; esac
        out+="$tok${UI_US}${seg#*"${UI_US}"}${UI_RS}"
    done
    UI_P="$out"
}
# ui_wrap <текст> <ширина> → массив UI_WRAP: перенос по словам.
ui_wrap() {
    local text="$1" w="$2" word line=""
    UI_WRAP=()
    for word in $text; do
        if [ -z "$line" ]; then line="$word"
        elif [ $(( ${#line} + 1 + ${#word} )) -le "$w" ]; then line+=" $word"
        else UI_WRAP+=("$line"); line="$word"; fi
    done
    [ -n "$line" ] && UI_WRAP+=("$line")
    return 0
}
# ui_spread <левое> <правое> <ширина> → UI_P: правое прижато к краю.
ui_spread() {
    local g
    ui_len "$1"; g=$UI_N; ui_len "$2"; g=$(( $3 - g - UI_N ))
    if [ "$g" -ge 1 ]; then printf -v UI_P '%s%s%*s%s%s' "$1" "text${UI_US}" "$g" '' "${UI_RS}" "$2"
    else UI_P="$1"; fi
}
# ui_bar <доля в тысячных> <ширина> <токен> → UI_BAR: шкала с шагом ⅛ клетки.
ui_bar() {
    local pm="$1" w="$2" tok="$3" c8 full part out=""
    local P=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
    [ "$pm" -lt 0 ] && pm=0; [ "$pm" -gt 1000 ] && pm=1000
    c8=$(( pm * w * 8 / 1000 )); full=$(( c8 / 8 )); part=$(( c8 % 8 ))
    ui_rep '█' "$full"; out+="$tok${UI_US}$UI_P${UI_RS}"
    if [ "$full" -lt "$w" ]; then
        if [ "$part" -gt 0 ]; then out+="$tok${UI_US}${P[$part]}${UI_RS}"; else out+="rule${UI_US}░${UI_RS}"; fi
        ui_rep '░' $(( w - full - 1 )); out+="rule${UI_US}$UI_P${UI_RS}"
    fi
    UI_BAR="$out"
}

# ── окна ───────────────────────────────────────────────────────────────
# Строки содержимого окна: UI_LS (сегменты) и UI_LSEL (1 — выделена).
ui_lclear() { UI_LS=(); UI_LSEL=(); }
ui_lpush() { UI_LS+=("$1"); UI_LSEL+=("${2:-0}"); }
# ui_frame2 <W> <H> <заголовок-сегменты> <правая метка-сегменты или ""> → UI_FR
# Верх «╔═ заголовок ═══ метка ═╗», бока «║…║», низ «╚══╝». Не влезает метка — её нет.
ui_frame2() {
    local W="$1" H="$2" title="$3" right="$4" top tr fill i l s pad
    UI_FR=()
    top="grad${UI_US}╔═ ${UI_RS}$title""grad${UI_US} ${UI_RS}"
    if [ -n "$right" ]; then tr="grad${UI_US} ${UI_RS}$right""grad${UI_US} ═╗${UI_RS}"; else tr="grad${UI_US}═╗${UI_RS}"; fi
    ui_len "$top"; fill=$UI_N; ui_len "$tr"; fill=$(( W - fill - UI_N ))
    if [ "$fill" -lt 1 ]; then tr="grad${UI_US}═╗${UI_RS}"; ui_len "$top"; fill=$(( W - UI_N - 2 )); fi
    [ "$fill" -lt 0 ] && fill=0
    ui_rep '═' "$fill"
    ui_fit "$top""grad${UI_US}$UI_P${UI_RS}$tr" "$W"; UI_FR+=("$UI_FIT")
    for ((i = 0; i < H; i++)); do
        l="${UI_LS[$i]:-}"; s="${UI_LSEL[$i]:-0}"
        if [ "$s" = 1 ]; then ui_sel "$l"; l="$UI_P"; fi
        ui_fit "$l" $(( W - 2 ))
        pad=$(( W - 2 - UI_FITN ))
        if [ "$s" = 1 ]; then printf -v l '%*s' "$pad" ''; l="text+sel${UI_US}$l${UI_RS}"
        else printf -v l '%*s' "$pad" ''; l="text${UI_US}$l${UI_RS}"; fi
        UI_FR+=("grad${UI_US}║${UI_RS}$UI_FIT$l""grad${UI_US}║${UI_RS}")
    done
    ui_rep '═' $(( W - 2 )); UI_FR+=("grad${UI_US}╚${UI_P}╝${UI_RS}")
}

# ── экран ──────────────────────────────────────────────────────────────
ui_body() { UI_BODY+=("$1"); }
# Подсказка клавиш: «клавиша|подпись|короткая|вид». Не влезает — ступенями:
# 1 — без подписи помеченные lab (s: «Защита» и так видна в меню), 2 — все
# подписи короткие (как в 1.1.0), 3 — второстепенных (opt: их буква видна у
# пункта) нет совсем. На 80 колонках строка — 1.1.0 плюс «s» (REVIEW-2 №3).
ui_keys() {
    local short="${1:-0}"; shift
    local s="text${UI_US}  ${UI_RS}" i=0 k l sh opt lab item
    for item in "$@"; do
        IFS='|' read -r k l sh opt <<<"$item"
        [ "$short" -ge 3 ] && [ "$opt" = opt ] && continue
        if [ "$short" -ge 2 ] || { [ "$short" = 1 ] && [ "$opt" = lab ]; }; then lab="$sh"; else lab="$l"; fi
        [ "$i" -gt 0 ] && s+="muted${UI_US} · ${UI_RS}"
        s+="key${UI_US}$k${UI_RS}"
        [ -n "$lab" ] && s+="muted${UI_US} $lab${UI_RS}"
        i=$(( i + 1 ))
    done
    UI_P="$s"
}
ui_keys_fit() {
    local lv
    for lv in 0 1 2 3; do ui_keys "$lv" "$@"; ui_len "$UI_P"; [ "$UI_N" -le "$UI_C" ] && break; done
    UI_KEYS="$UI_P"
}

# ui_compose → UI_ROWS: тело, добитое до UI_R строк, внизу сведения и клавиши.
# Выделенная строка тела помечается префиксом «+» и заливается до края.
ui_compose() {
    local foot=0 i row n
    UI_ROWS=()
    [ -n "$UI_INFO" ] && foot=$(( foot + 1 )); [ -n "$UI_KEYS" ] && foot=$(( foot + 1 ))
    n=$(( UI_R - foot ))
    for ((i = 0; i < n; i++)); do
        row="${UI_BODY[$i]:-}"
        if [ "${row:0:1}" = $'\x1d' ]; then
            row="${row:1}"; ui_fit "$row" "$UI_C"; row="$UI_FIT"
            ui_sel "$row"; row="$UI_P"
            printf -v UI_P '%*s' $(( UI_C - UI_FITN )) ''
            row+="text+sel${UI_US}$UI_P${UI_RS}"
        else
            ui_fit "$row" "$UI_C"; row="$UI_FIT"
        fi
        UI_ROWS+=("$row")
    done
    [ -n "$UI_INFO" ] && { ui_fit "$UI_INFO" "$UI_C"; UI_ROWS+=("$UI_FIT"); }
    if [ -n "$UI_KEYS" ]; then
        local keys="$UI_KEYS" f2
        # Подсказка про размер — только там, где выбирать есть из чего.
        if [ "${UI_COLS:-80}" -gt 80 ] && [ "${UI_LINES:-24}" -ge 24 ]; then
            ut "размер" "size"; f2="$UI_TX"
            keys+="muted${UI_US} · ${UI_RS}key${UI_US}F2${UI_RS}muted${UI_US} ${f2}${UI_RS}"
        fi
        ui_fit "$keys" "$UI_C"; UI_ROWS+=("$UI_FIT")
    fi
    return 0
}
# ui_selrow <сегменты> — выделенная строка тела (заливка до края экрана).
ui_selrow() { UI_BODY+=($'\x1d'"$1"); }

# ui_ascii <текст> → UI_P: замены по таблице, каждая в одну клетку.
ui_ascii() {
    local s="$1" k
    for k in "${!UI_ASC[@]}"; do [[ "$s" == *"$k"* ]] && s="${s//"$k"/"${UI_ASC[$k]}"}"; done
    UI_P="$s"
}

# ui_emit — напечатать UI_ROWS поверх экрана: курсор в начало, каждая строка
# гасит хвост, в конце — остаток экрана. Последняя строка без перевода:
# иначе на окне ровно в 24 строки экран прокрутится.
ui_emit() {
    local out=$'\033[H' row seg tok txt sel s col k i=0 n="${#UI_ROWS[@]}" pad="" t
    # Отступы до холста — по выбранному размеру (ui_size): по центру окна.
    for ((t = 0; t < ${UI_PADT:-0}; t++)); do out+=$'\033[K\n'; done
    [ "${UI_PADL:-0}" -gt 0 ] && printf -v pad '%*s' "$UI_PADL" ''
    for row in "${UI_ROWS[@]}"; do
        out+="$pad"
        col=0
        while [ -n "$row" ]; do
            seg="${row%%"${UI_RS}"*}"; row="${row#*"${UI_RS}"}"
            tok="${seg%%"${UI_US}"*}"; txt="${seg#*"${UI_US}"}"
            [ -n "$txt" ] || continue
            [ "$UI_ASCII" = 1 ] && { ui_ascii "$txt"; txt="$UI_P"; }
            sel=0; case "$tok" in *+sel) sel=1; tok="${tok%+sel}" ;; esac
            if [ "$tok" = grad ] && [ "$UI_GRADN" -gt 0 ]; then
                for ((k = 0; k < ${#txt}; k++)); do out+="${UI_GRAD[$(( col + k < UI_GRADN ? col + k : UI_GRADN - 1 ))]}${txt:k:1}"; done
            else
                if [ "$sel" = 1 ]; then s="${UI_SGRSEL[$tok]:-}"; else s="${UI_SGR[$tok]:-}"; fi
                out+="$s$txt"
            fi
            col=$(( col + ${#txt} ))
        done
        i=$(( i + 1 ))
        out+=$'\033[0m\033[K'
        [ "$i" -lt "$n" ] && out+=$'\n'
    done
    out+=$'\033[J'
    printf '%s' "$out"
}
# ui_dump — строки экрана для сверки: «текст␉токен:длина,…».
ui_dump() {
    local row seg tok txt text runs
    for row in "${UI_ROWS[@]}"; do
        text=""; runs=""
        while [ -n "$row" ]; do
            seg="${row%%"${UI_RS}"*}"; row="${row#*"${UI_RS}"}"
            tok="${seg%%"${UI_US}"*}"; txt="${seg#*"${UI_US}"}"
            [ -n "$txt" ] || continue
            text+="$txt"; runs+="$tok:${#txt},"
        done
        printf '%s\t%s\n' "$text" "$runs"
    done
}

# ── модель: что показывать ─────────────────────────────────────────────
# Боевой код заполняет её из системы (ui_model_load), тест — данными примера
# из пакета и так сверяет раскладку с эталоном клетка в клетку. Индекс — номер
# продукта в PRODUCTS.
UD_HOST=""; UD_OS=""; UD_VER=""; UD_VERNEW=""; UD_SELFREF=""; UD_SVED=""; UD_DISK=0; UD_MEM=0; UD_LOAD=""
UD_NAME=(); UD_CMD=(); UD_DESC=(); UD_INST=(); UD_SRV=(); UD_MAIN=(); UD_DEV=(); UD_BRANCH=()
# UD_DEVREF — имя второй ветки (dev или develop);
# UD_UPDV — версия, до которой обновится стоящий, с его же ветки. Пусто —
# dev и UD_MAIN, как в данных примера.
UD_DEVREF=(); UD_UPDV=()
UD_UPD=(); UD_NEW=(); UD_ST=(); UD_STTXT=(); UD_MODES=(); UD_DEFMODE=(); UD_SVC=(); UD_SVCOK=(); UD_HELD=()
UD_NEED=(); UD_VBAD=(); UD_VNOTES=(); UD_VWHY=()
UD_PROB=()          # замечания: «имя|что|коротко|шаг[|err]»; err — ✗, иначе !
UD_KEYNOTE=""; UD_KEYTOK="muted"; UD_LANGNOTE=""
UI_POLL=""          # «N» — идёт опрос GitHub, ответили N из 8
UI_POLLDIR=""; UI_POLLPID=""; UI_ALT=0
UI_POLLERR=""       # github | rate — чем кончился последний опрос

# ut <ru> <en> → UI_TX. Без подоболочки: экран перерисовывается на каждое
# нажатие, и вилка на каждую строку текста ощутимо тормозит отклик.
ut() { if [ "${LANG_CODE:-ru}" = en ]; then UI_TX="$2"; else UI_TX="$1"; fi; }
_s() { UI_SEG+="$1${UI_US}$2${UI_RS}"; }   # _s <токен> <текст> — к собираемой строке

# Значок, токен и слово статуса продукта (STATUS в прототипе).
_ui_st() {
    case "${UD_ST[$1]}" in
        installed) UI_G='●'; UI_GT=ok;    ut "установлен" "installed"; UI_SW="$UI_TX" ;;
        ready)     UI_G='○'; UI_GT=muted; ut "готов" "ready"; UI_SW="$UI_TX" ;;
        notes)     UI_G='!'; UI_GT=warn;  ut "готов, есть замечания" "ready, with notes"; UI_SW="$UI_TX" ;;
        lite|free) UI_G='◆'; UI_GT=warn;  UI_SW="${UD_STTXT[$1]}" ;;
        *)         UI_G='✗'; UI_GT=err;   UI_SW="${UD_STTXT[$1]}" ;;
    esac
}
_ui_modename() {
    case "$1" in
        lazy) ut "Ленивый pro" "Lazy pro" ;;
        lite_site) UI_TX="Semi-pro" ;;
        lite) UI_TX="Lite" ;;
        *) UI_TX="$1" ;;
    esac
}
# Итог проверки портов тегом: «✗ препятствий: 2», «! замечаний: 1», «✓ готов».
_ui_verdict() {
    local bad="${UD_VBAD[$1]:-0}" notes="${UD_VNOTES[$1]:-0}"
    if [ "$bad" -gt 0 ]; then ut "препятствий: " "obstacles: "; UI_VT="✗ $UI_TX$bad"; UI_VK=err
    elif [ "$notes" -gt 0 ]; then ut "замечаний: " "notes: "; UI_VT="! $UI_TX$notes"; UI_VK=warn
    else ut "готов" "ready"; UI_VT="✓ $UI_TX"; UI_VK=ok; fi
}

# ── общие строки ───────────────────────────────────────────────────────
# Строка состояния наверху: имя и сервер слева, диск, память, нагрузка справа.
ui_hud() {
    local n=0 left right pm tok h="$UD_HOST" room lw
    [ "$UI_C" -lt 60 ] && n=1
    UI_SEG=""
    _ui_meter() {  # _ui_meter <подпись> <проценты> <ширина>
        pm=$(( $2 * 10 )); if [ "$2" -lt 70 ]; then tok=ok; elif [ "$2" -lt 90 ]; then tok=warn; else tok=err; fi
        _s muted "$1 "; _s rule "▕"; ui_bar "$pm" "$3" "$tok"; UI_SEG+="$UI_BAR"; _s rule "▏"; _s text "$2 %"
    }
    ut "диск" "disk"; _ui_meter "$UI_TX" "$UD_DISK" $(( n ? 4 : 6 ))
    if [ "$n" = 1 ]; then ut "озу" "mem"; _s muted "  $UI_TX "; _s text "$UD_MEM % "
    else _s text "  "; ut "озу" "mem"; _ui_meter "$UI_TX" "$UD_MEM" 6; ut "нагр" "load"; _s muted "  $UI_TX "; _s text "$UD_LOAD "; fi
    right="$UI_SEG"
    # Длинное имя машины (у облаков это обычно: ubuntu-s-1vcpu-1gb-fra1-01)
    # сокращаем с «…»: иначе ui_spread отбросил бы диск, память и нагрузку
    # целиком.
    UI_SEG=""; _s title " goInstaller"; _s muted " $UD_VER"
    if [ "$n" = 0 ]; then
        ui_len "$UI_SEG"; lw=$UI_N; ui_len "$right"
        room=$(( UI_C - lw - 5 - UI_N - 2 ))
        if [ "${#h}" -gt "$room" ]; then if [ "$room" -ge 4 ]; then h="${h:0:$(( room - 1 ))}…"; else h=""; fi; fi
        [ -n "$h" ] && _s text "  ·  $h"
    fi
    left="$UI_SEG"
    ui_spread "$left" "$right" "$UI_C"; ui_body "$UI_P"
}
# Заголовок экранов без окон: «  goInstaller 0.9.5 …… vpn-fin-1» и черта.
ui_hdr() {  # ui_hdr <левое-сегменты> [правая подпись]
    local right=""
    [ -n "${2:-}" ] && right="muted${UI_US}$2${UI_RS}"
    ui_spread "text${UI_US}  ${UI_RS}$1" "$right" "$UI_C"; ui_fit "$UI_P" "$UI_C"; ui_body "$UI_FIT"
    ui_rep '═' $(( UI_C - 4 )); ui_body "grad${UI_US}  $UI_P${UI_RS}"
}
ui_main_title() { UI_SEG=""; _s title "goInstaller"; _s muted " $UD_VER"; UI_MT="$UI_SEG"; }

# Сведения под меню: опрос идёт, GitHub молчит, лимит или время последнего опроса.
ui_menu_info() {
    UI_SEG=""
    if [ -n "$UI_POLL" ]; then
        _s cursor "  ${UI_SPIN:-⠋}"; ut " опрос GitHub: " " GitHub poll: "; local a="$UI_TX"; ut " из 8" " of 8"; _s muted "$a$UI_POLL$UI_TX"
    elif [ "$UI_POLLERR" = github ]; then
        _s err "  ✗ "; ut "GitHub недоступен · сведения от " "GitHub unreachable · data as of "; _s muted "$UI_TX$UD_SVED"
    elif [ "$UI_POLLERR" = rate ]; then
        _s warn "  ! "; ut "лимит GitHub, повтор в ${UI_RESET:-?} · сведения от " "GitHub rate limit, retry at ${UI_RESET:-?} · data as of "; _s muted "$UI_TX$UD_SVED"
    else
        ut "сведения от " "data as of "; local a="$UI_TX"
        # «Обновляются сами» — только когда меню и правда спрашивает GitHub по
        # таймеру: минуты — из GOINST_MENU_REFRESH, без сети и при 0 — молчим.
        local rf="${GOINST_MENU_REFRESH:-180}"; case "$rf" in ''|*[!0-9]*) rf=0 ;; esac
        if [ "$UI_C" -lt 60 ] || [ -n "${GOINST_NO_NET:-}" ] || [ -z "${TOKEN:-}" ] || [ "$rf" -le 0 ]; then _s muted "  $a$UD_SVED"
        else
            if [ "$rf" -ge 60 ]; then ut " · обновляются сами раз в $(( (rf + 30) / 60 )) мин" " · refresh every $(( (rf + 30) / 60 )) min by themselves"
            else ut " · обновляются сами раз в ${rf} с" " · refresh every ${rf} s by themselves"; fi
            _s muted "  $a$UD_SVED$UI_TX"
        fi
    fi
    UI_INFO="$UI_SEG"
}
ui_menu_keys() {
    local a=() k1 k2
    ut "сразу" "jump"; k1="$UI_TX"
    a=("↑↓||" "Enter||" "1–9|$k1|")
    if [ -n "$UD_VERNEW" ]; then ut "обновить" "update"; a+=("u|$UI_TX|"); fi
    [ -n "${UD_OSUP:-}" ] && a+=("o|Ubuntu|")
    ut "защита" "protection"; a+=("s|$UI_TX||lab")
    ut "порты" "ports"; a+=("p|$UI_TX||opt"); ut "ключ" "key"; a+=("r|$UI_TX||opt"); ut "язык" "language"; a+=("l|$UI_TX||opt")
    ut "выход" "quit"; a+=("0|$UI_TX|$UI_TX")
    ui_keys_fit "${a[@]}"
}
# Замечания под меню: полная строка на 80 колонках, короткая на 46.
ui_alerts() {  # ui_alerts <80|46> [сколько строк есть]
    local p name msg short step sev g t i=0 n="${#UD_PROB[@]}" max="${2:-}"
    case "$max" in ''|*[!0-9]*) max=$n ;; esac
    for p in "${UD_PROB[@]}"; do
        # Не влезают все — последняя строка «… ещё N»: молча пропавшая
        # тревога хуже обрезанного списка.
        if [ "$n" -gt "$max" ] && [ "$i" -ge $(( max - 1 )) ]; then
            [ "$max" -gt 0 ] || return 0
            UI_SEG=""; ut "ещё $(( n - i ))" "$(( n - i )) more"
            if [ "$1" = 80 ]; then _s muted " … "; else _s muted "  … "; fi
            _s text "$UI_TX"; ui_body "$UI_SEG"; return 0
        fi
        i=$(( i + 1 ))
        IFS='|' read -r name msg short step sev <<<"$p"
        case "$sev" in err) g='✗'; t=err ;; ok) g='✓'; t=ok ;; *) g='!'; t=warn ;; esac
        UI_SEG=""
        if [ "$1" = 80 ]; then _s "$t" " $g "; _s text "$name: $msg"; _s muted " → "; _s key "$step"
        else _s "$t" "  $g "; _s text "$short"; fi
        ui_body "$UI_SEG"
    done
}

# ── пункты главного меню ───────────────────────────────────────────────
ui_menu_items() {
    local i
    MI_KIND=(); MI_KEY=(); MI_HOT=(); MI_LABEL=(); MI_NOTE=(); MI_NTOK=(); MI_TOK=(); MI_P=()
    _mi() { MI_KIND+=("$1"); MI_KEY+=("$2"); MI_HOT+=("$3"); MI_LABEL+=("$4"); MI_NOTE+=("$5"); MI_NTOK+=("${6:-muted}"); MI_TOK+=("${7:-}"); MI_P+=("${8:--1}"); }
    for ((i = 0; i < ${#UD_NAME[@]}; i++)); do _mi p "$(( i + 1 ))" "" "${UD_NAME[$i]}" "" muted "" "$i"; done
    local a b
    # Обновление Ubuntu — первым из служебных, сразу под чертой.
    if [ -n "${UD_OSUP:-}" ]; then
        case "$UD_OSUP" in run) b=warn ;; fail) b=err ;; done) b=ok ;; cont) b=muted ;; *) b="" ;; esac
        ut "обновить систему до Ubuntu ${OSUP_TARGET} LTS одной кнопкой" "upgrade the system to Ubuntu ${OSUP_TARGET} LTS with one key"
        _mi s o o "$UD_OSUPLBL" "$UI_TX" muted "$b"
    fi
    ut "Карта портов" "Port map"; a="$UI_TX"; ut "кто какие порты держит" "who holds which ports"; _mi s 7 p "$a" "$UI_TX"
    ut "Ключ доступа" "Access key"; _mi s 8 r "$UI_TX" "$UD_KEYNOTE" "$UD_KEYTOK"
    ut "Язык" "Language"; _mi s 9 l "$UI_TX" "$UD_LANGNOTE"
    ut "Компоненты" "Components"; a="$UI_TX"; ut "системные пакеты продуктов: что стоит и что доступно" "the products' system packages: what is installed and what is available"; _mi s c "" "$a" "$UI_TX"
    ut "Защита от сканеров" "Scanner protection"; a="$UI_TX"
    case "${SHS_ST:-none}" in
        ok)  _mi s s "" "$a" "${SHS_TEXT:-}" ok ;;
        bad) _mi s s "" "$a" "${SHS_TEXT:-}: ${SHS_WHY:-}" err ;;
        off) ut "выключена: сканеры и ВК видят порты сервера" "off: scanners and VK see the server's ports"; _mi s s "" "$a" "$UI_TX" ;;
        *)   ut "сети госорганов и ВК, которые сканируют серверы, не увидят портов" "government and VK networks that scan servers will not see the ports"; _mi s s "" "$a" "$UI_TX" ;;
    esac
    if [ -n "$UD_VERNEW" ]; then ut "Обновить goInstaller" "Update goInstaller"; _mi s u "" "$UI_TX" "$UD_VER → $UD_VERNEW" update update; fi
    ut "Удалить goInstaller" "Remove goInstaller"; _mi s x "" "$UI_TX" ""
    ut "Выход" "Quit"; _mi s 0 q "$UI_TX" ""
}

# Левое окно «ПРОДУКТЫ» (arcadeList): продукты, черта, служебные пункты.
ui_arcade_list() {  # ui_arcade_list <cur> <W> → UI_LS/UI_LSEL
    local cur="$1" W="$2" i n="${#MI_KEY[@]}" sel p g gt
    ui_lclear
    for ((i = 0; i < n; i++)); do
        sel=0; [ "$i" = "$cur" ] && sel=1
        UI_SEG=""; _s text " "
        if [ "$sel" = 1 ]; then _s cursor "▸ "; _s cursor "${MI_KEY[$i]} "; else _s cursor "  "; _s muted "${MI_KEY[$i]} "; fi
        if [ "${MI_KIND[$i]}" = p ]; then
            p="${MI_P[$i]}"
            if [ "${UD_UPD[$p]:-0}" = 1 ]; then g="↑ ${UD_UPDV[$p]:-${UD_MAIN[$p]}}"; gt=update
            elif [ "${UD_NEW[$p]:-0}" = 1 ]; then ut "новое" "new"; g="✚ $UI_TX"; gt=new
            elif [ "${UD_ST[$p]}" = free ]; then ut "бесплатный" "free"; g="◆ $UI_TX"; gt=warn
            elif [ "${UD_INST[$p]:-0}" = 1 ]; then g="● ${UD_SRV[$p]}"; gt=ok
            else case "${UD_ST[$p]}" in
                notes) ut "замечания" "notes"; g="! $UI_TX"; gt=warn ;;
                lite)  g="◆ ${UD_STTXT[$p]}"; gt=warn ;;
                block) ut "нельзя" "blocked"; g="✗ $UI_TX"; gt=err ;;
                *)     ut "готов" "ready"; g="○ $UI_TX"; gt=muted ;;
            esac; fi
            ui_padr "${MI_LABEL[$i]}" 16
            if [ "$sel" = 1 ]; then _s title "$UI_P"; else _s name "$UI_P"; fi
            _s "$gt" "$g"
        elif [ "${MI_KEY[$i]}" = o ]; then
            # Подпись хода длинная («Ubuntu: обновление, шаг 3 из 7») — без буквы справа.
            if [ "${UD_OSUP:-}" = can ]; then ui_padr "${MI_LABEL[$i]}" $(( W - 11 )); else ui_padr "${MI_LABEL[$i]}" $(( W - 5 )); fi
            if [ "$sel" = 1 ]; then _s title "$UI_P"; else _s "${MI_TOK[$i]:-name}" "$UI_P"; fi
            [ "${UD_OSUP:-}" = can ] && _s update "↑"
        else
            ui_padr "${MI_LABEL[$i]}" $(( W - 11 ))
            if [ "$sel" = 1 ]; then _s title "$UI_P"; else _s "${MI_TOK[$i]:-name}" "$UI_P"; fi
            if [ "${MI_KEY[$i]}" = c ] && [ "${UD_COMPUP:-0}" -gt 0 ]; then _s update "↑${UD_COMPUP}"
            elif [ "${MI_KEY[$i]}" = s ] && [ "${SHS_ST:-}" = bad ]; then _s err "✗"
            else _s key "${MI_HOT[$i]}"; fi
        fi
        ui_lpush "$UI_SEG" "$sel"
        if [ "$i" = 5 ]; then ui_rep '─' $(( W - 4 )); ui_lpush "rule${UI_US} $UI_P${UI_RS}" 0; fi
    done
    # Защита стоит и считает — внизу окна вход и выход за 7 дней (вариант A).
    if ui_sh_live && [ "${#UI_LS[@]}" -le 15 ]; then
        while [ "${#UI_LS[@]}" -lt 15 ]; do ui_lpush "" 0; done
        ui_sh_lineA; ui_lpush "text${UI_US} ${UI_RS}$UI_P" 0
    fi
    return 0
}

# Карточка выбранного пункта (arcadeCard). «ЧТО НОВОГО» заказчик убрал.
ui_arcade_card() {  # ui_arcade_card <пункт> <IW> <H> [в меню продукта] → UI_LS, UI_CT, UI_CR
    local it="$1" IW="$2" H="$3" inprod="${4:-0}" p l i foot u
    ui_lclear
    _P() { ui_lpush "text${UI_US} ${UI_RS}$1" 0; }
    if [ "${MI_KIND[$it]}" = p ]; then
        p="${MI_P[$it]}"; _ui_st "$p"
        UI_CT="title${UI_US}${UD_NAME[$p]}${UI_RS}"
        local wt="$UI_GT"; [ "$wt" = muted ] && wt=text
        UI_CR="$UI_GT${UI_US}$UI_G ${UI_RS}$wt${UI_US}$UI_SW${UI_RS}"
        ui_wrap "${UD_DESC[$p]}" $(( IW - 2 ))
        for ((i = 0; i < ${#UI_WRAP[@]} && i < 2; i++)); do _P "muted${UI_US}${UI_WRAP[$i]}${UI_RS}"; done
        _P ""
        ut "ВЕТКА" "BRANCH"; ui_padr "$UI_TX" 8; l="$UI_P"; ut "СЕРВЕР" "SERVER"; ui_padr "$UI_TX" 10; _P "muted${UI_US}$l${UI_P}GITHUB${UI_RS}"
        local inst="${UD_INST[$p]:-0}" br="${UD_BRANCH[$p]:-main}" upd="${UD_UPD[$p]:-0}" new="${UD_NEW[$p]:-0}" dr="${UD_DEVREF[$p]:-dev}"
        # Обновление — на строке той ветки, с которой стоит.
        local upm=0 upd2=0; [ "$upd" = 1 ] && { if [ "$br" = "$dr" ] && [ -n "${UD_DEV[$p]:-}" ]; then upd2=1; else upm=1; fi; }
        UI_SEG=""
        ui_padr main 8; if [ "$inst" = 1 ] && [ "$br" = main ]; then _s title "$UI_P"; else _s text "$UI_P"; fi
        if [ "$inst" = 1 ] && [ "$br" = main ]; then ui_padr "${UD_SRV[$p]}" 10; else ui_padr "—" 10; fi
        if [ "$upm" = 1 ]; then _s update "$UI_P"; else _s text "$UI_P"; fi
        ui_padr "${UD_MAIN[$p]:-—}" 9
        if [ "$upm" = 1 ]; then _s update "$UI_P"; ut "новее" "newer"; _s update "↑ $UI_TX"
        elif [ "$new" = 1 ]; then _s new "$UI_P"; ut "новое" "new"; _s new "✚ $UI_TX"
        else _s text "$UI_P"; fi
        _P "$UI_SEG"
        UI_SEG=""
        ui_padr "$dr" 8; if [ "$inst" = 1 ] && [ "$br" = "$dr" ]; then _s title "$UI_P"; else _s text "$UI_P"; fi
        if [ "$inst" = 1 ] && [ "$br" = "$dr" ]; then ui_padr "${UD_SRV[$p]}" 10; else ui_padr "—" 10; fi
        _s text "$UI_P"
        if [ "$upd2" = 1 ]; then ui_padr "${UD_DEV[$p]}" 9; _s update "$UI_P"; ut "новее" "newer"; _s update "↑ $UI_TX"
        elif [ -n "${UD_DEV[$p]:-}" ]; then _s muted "${UD_DEV[$p]}"; else ut "нет ветки" "no branch"; _s muted "$UI_TX"; fi
        _P "$UI_SEG"
        _P ""
        if [ "$inst" = 1 ]; then
            ui_wrap "${UD_HELD[$p]:-—}" $(( IW - 10 ))
            for ((i = 0; i < ${#UI_WRAP[@]}; i++)); do
                if [ "$i" = 0 ]; then ut "ПОРТЫ" "PORTS"; ui_padr "$UI_TX" 8; else ui_padr "" 8; fi
                _P "muted${UI_US}$UI_P${UI_RS}text${UI_US}${UI_WRAP[$i]}${UI_RS}"
            done
            UI_SEG=""; ut "СЛУЖБЫ" "UNITS"; ui_padr "$UI_TX" 8; _s muted "$UI_P"
            local k=0 ok
            for u in ${UD_SVC[$p]:-}; do
                ok=1; case " ${UD_SVCOK[$p]:-} " in *" $u:0 "*) ok=0 ;; *" $u:2 "*) ok=2 ;; esac
                local sp=""; [ "$k" -gt 0 ] && sp="  "
                case "$ok" in 1) _s ok "${sp}● " ;; 2) _s muted "${sp}○ " ;; *) _s err "${sp}✗ " ;; esac
                _s text "$u"; k=$(( k + 1 ))
            done
            [ "$k" -gt 0 ] || _s text "—"
            _P "$UI_SEG"
        else
            ui_wrap "${UD_NEED[$p]:-—}" $(( IW - 10 ))
            for ((i = 0; i < ${#UI_WRAP[@]} && i < 2; i++)); do
                if [ "$i" = 0 ]; then ut "НУЖНЫ" "NEEDS"; ui_padr "$UI_TX" 8; else ui_padr "" 8; fi
                _P "muted${UI_US}$UI_P${UI_RS}text${UI_US}${UI_WRAP[$i]}${UI_RS}"
            done
            UI_SEG=""; ut "ИТОГ" "RESULT"; ui_padr "$UI_TX" 8; _s muted "$UI_P"
            _ui_verdict "$p"; _s "$UI_VK" "$UI_VT"
            if [ -n "${UD_MODES[$p]:-}" ]; then _ui_modename "${UD_DEFMODE[$p]}"; _s muted " · $UI_TX"; fi
            _P "$UI_SEG"
            if [ -n "${UD_VWHY[$p]:-}" ] && [ "$UI_VK" != ok ]; then
                ui_wrap "${UD_VWHY[$p]}" $(( IW - 10 ))
                for ((i = 0; i < ${#UI_WRAP[@]} && i < 4; i++)); do ui_padr "" 8; _P "muted${UI_US}$UI_P${UI_RS}${UI_VK}${UI_US}${UI_WRAP[$i]}${UI_RS}"; done
            fi
        fi
        UI_SEG=""
        if [ "$inprod" = 1 ]; then ut "команда " "command "; _s muted "$UI_TX"; _s key "${UD_CMD[$p]}"
        else
            _s key "Enter"
            if [ "$inst" = 1 ] && [ "${UD_ST[$p]}" != free ]; then ut " — меню продукта" " — product menu"; else ut " — установка" " — install"; fi
            _s muted "$UI_TX"; _s rule "  ·  "; _s key "${UD_CMD[$p]}"
        fi
        foot="$UI_SEG"
    else
        UI_CT="${MI_TOK[$it]:-title}${UI_US}${MI_LABEL[$it]}${UI_RS}"; UI_CR=""
        if [ "${MI_KEY[$it]}" = o ]; then
            ui_osup_cardlines $(( IW - 2 )); UI_CT="$UI_OCT"; UI_CR="$UI_OCR"
            for l in ${UI_OCL[@]+"${UI_OCL[@]}"}; do _P "$l"; done
        elif [ "${MI_KEY[$it]}" = s ] && ui_sh_inst; then
            ui_sh_card "${UI_SHROW:-6}"; UI_CT="$UI_SCT"; UI_CR="$UI_SCRT"
            for l in "${UI_SCL[@]}"; do _P "$l"; done
        else
        if [ -n "${MI_NOTE[$it]}" ]; then
            ui_wrap "${MI_NOTE[$it]}" $(( IW - 2 ))
            for l in "${UI_WRAP[@]}"; do _P "${MI_NTOK[$it]:-muted}${UI_US}$l${UI_RS}"; done
        fi
        _P ""
        fi
        case "${MI_KEY[$it]}" in
            7) local q h port proc
               for ((q = 0; q < ${#UD_NAME[@]}; q++)); do
                   [ "${UD_INST[$q]:-0}" = 1 ] || continue
                   local c=0
                   for h in ${UD_HELDP[$q]:-}; do
                       [ "$c" -lt 2 ] || break
                       port="${h%%=*}"; proc="${h#*=}"
                       ui_padr "$port" 10; l="$UI_P"; ui_padr "$proc" 8; UI_P+=" "
                       _P "text${UI_US}$l${UI_RS}muted${UI_US}$UI_P${UI_RS}muted${UI_US}${UD_NAME[$q]}${UI_RS}"
                       c=$(( c + 1 ))
                   done
               done ;;
            8) _P "muted${UI_US}${TOKEN_FILE:-/opt/go-installer/token}${UI_RS}"; ut "режим 0600, только root" "mode 0600, root only"; _P "muted${UI_US}$UI_TX${UI_RS}" ;;
            9) _P "key${UI_US}1${UI_RS}text${UI_US} Русский   ${UI_RS}key${UI_US}2${UI_RS}text${UI_US} English${UI_RS}" ;;
            u) ut "ветка main · " "branch main · "; _P "muted${UI_US}$UI_TX${UI_RS}text${UI_US}go-installer.sh${UI_RS}" ;;
            c) ui_comps_cardlines $(( IW - 2 )); for l in ${UI_CCL[@]+"${UI_CCL[@]}"}; do _P "$l"; done ;;
            s) ui_sh_inst || { ui_shield_cardlines; for l in ${UI_SCL[@]+"${UI_SCL[@]}"}; do _P "$l"; done; } ;;
            0) ut "вернуться в консоль" "back to the shell"; _P "muted${UI_US}$UI_TX${UI_RS}" ;;
        esac
        UI_SEG=""
        if [ "${MI_KEY[$it]}" = s ] && ui_sh_inst; then
            _s key "Enter"; ut " — меню «Защита»" " — protection menu"; _s muted "$UI_TX"
            if ui_sh_cardok; then _s rule "  ·  "; _s key "←→"; ut " день" " day"; _s muted "$UI_TX"; fi
        elif [ -n "${MI_HOT[$it]}" ]; then
            _s key "Enter"; ut " или " " or "; _s muted "$UI_TX"; _s key "${MI_HOT[$it]}"; ut " с любого экрана" " from any screen"; _s muted "$UI_TX"
        else _s key "Enter"; ut " — открыть" " — open"; _s muted "$UI_TX"; fi
        foot="$UI_SEG"
    fi
    while [ "${#UI_LS[@]}" -lt $(( H - 1 )) ]; do ui_lpush "" 0; done
    UI_LS=("${UI_LS[@]:0:$(( H - 1 ))}"); UI_LSEL=("${UI_LSEL[@]:0:$(( H - 1 ))}")
    ui_lpush "text${UI_US} ${UI_RS}$foot" 0
}

# Главное меню. От 80 колонок — два окна (arcadeMenu), уже — список (g1).
ui_scr_menu() {  # ui_scr_menu <cur>
    local cur="$1" i LW=37 RW H=16 lf rf p db="" room cnt=0 l
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_menu_items
    if [ "$UI_C" -ge 80 ]; then
        RW=$(( UI_C - LW - 2 ))
        ui_hud
        ui_arcade_list "$cur" "$LW"
        ut "ПРОДУКТЫ" "PRODUCTS"; ui_frame2 "$LW" "$H" "title${UI_US}$UI_TX${UI_RS}" ""; lf=("${UI_FR[@]}")
        ui_arcade_card "$cur" $(( RW - 2 )) "$H"
        ui_frame2 "$RW" "$H" "$UI_CT" "$UI_CR"; rf=("${UI_FR[@]}")
        for ((i = 0; i < H + 2; i++)); do
            if [ "$i" = 0 ]; then p=" "; else p="░"; fi
            ui_body "${lf[$i]}shadow${UI_US}$p${UI_RS}${rf[$i]}shadow${UI_US}$p${UI_RS}"
        done
        ui_rep '░' "$LW"; lf="$UI_P"; ui_rep '░' "$RW"
        ui_body "text${UI_US} ${UI_RS}""shadow${UI_US}$lf${UI_RS}""text${UI_US} ${UI_RS}""shadow${UI_US}$UI_P${UI_RS}"
        ui_alerts 80 $(( UI_R - 2 - ${#UI_BODY[@]} ))
    else
        ui_main_title; ui_hdr "$UI_MT" "$UD_HOST"
        for ((i = 0; i < ${#MI_KEY[@]}; i++)); do
            UI_SEG=""
            if [ "$i" = "$cur" ]; then _s cursor "▸ "; _s cursor "${MI_KEY[$i]} "; else _s cursor "  "; _s muted "${MI_KEY[$i]} "; fi
            if [ "${MI_KIND[$i]}" = p ]; then
                p="${MI_P[$i]}"; _ui_st "$p"
                ui_padr "${MI_LABEL[$i]}" 15
                if [ "$i" = "$cur" ]; then _s title "$UI_P"; else _s name "$UI_P"; fi
                if [ "${UD_UPD[$p]:-0}" = 1 ]; then _s update "↑"; _s text " "; _s update "${UD_SRV[$p]} → ${UD_UPDV[$p]:-${UD_MAIN[$p]}}"
                elif [ "${UD_NEW[$p]:-0}" = 1 ]; then _s new "✚"; _s text " "; ut "новое · " "new · "; _s new "$UI_TX$UI_SW"
                elif [ "${UD_INST[$p]:-0}" = 1 ]; then _s "$UI_GT" "$UI_G"; _s text " "; _s text "$UI_SW ${UD_SRV[$p]}"
                else _s "$UI_GT" "$UI_G"; _s text " "; if [ "${UD_ST[$p]}" = ready ]; then _s text "$UI_SW"; else _s warn "$UI_SW"; fi; fi
            else
                if [ "${MI_KEY[$i]}" = 9 ]; then ui_padr "${MI_LABEL[$i]} · ${MI_NOTE[$i]}" 34; else ui_padr "${MI_LABEL[$i]}" 34; fi
                if [ "$i" = "$cur" ]; then _s title "$UI_P"; else _s "${MI_TOK[$i]:-name}" "$UI_P"; fi
                if [ "${MI_KEY[$i]}" = c ] && [ "${UD_COMPUP:-0}" -gt 0 ]; then _s update "↑${UD_COMPUP}"
                elif [ "${MI_KEY[$i]}" = s ] && [ "${SHS_ST:-}" = bad ]; then _s err "✗"
                elif [ "${MI_KEY[$i]}" = o ]; then [ "${UD_OSUP:-}" = can ] && _s update "↑"
                else _s key "${MI_HOT[$i]}"; fi
            fi
            if [ "$i" = "$cur" ]; then ui_selrow "$UI_SEG"; else ui_body "$UI_SEG"; fi
            if [ "$i" = 5 ]; then
                db=${#UI_BODY[@]}
                # Курсор на «Защите» — счётчики за сутки вместо описания.
                if [ "${MI_KEY[$cur]}" = s ] && ui_sh_live; then
                    cnt=1; ui_sh_counters; for l in "${UI_SHCN[@]}"; do ui_body "$l"; done
                else
                    ui_body ""
                    if [ "${MI_KIND[$cur]}" = p ]; then ui_body "muted${UI_US}  ${UD_DESC[${MI_P[$cur]}]}${UI_RS}"
                    else ui_body "${MI_NTOK[$cur]:-muted}${UI_US}  ${MI_NOTE[$cur]}${UI_RS}"; fi
                    ui_body ""
                fi
            fi
        done
        # Пунктов много (o, u и s вместе) и тревог несколько: сначала без
        # пустых строк вокруг описания, потом без пустой над тревогами; не
        # влезло и так — последняя строка «… ещё N», а не молча пропавшая.
        room=$(( UI_R - 2 ))
        if [ -n "$db" ] && [ $(( ${#UI_BODY[@]} + ${#UD_PROB[@]} )) -gt "$room" ]; then
            # Счётчики защиты теряют подпись «за сутки: …», описание — пустые строки.
            if [ "$cnt" = 1 ]; then UI_BODY=("${UI_BODY[@]:0:db+2}" "${UI_BODY[@]:db+3}")
            else UI_BODY=("${UI_BODY[@]:0:db}" "${UI_BODY[db+1]}" "${UI_BODY[@]:db+3}"); fi
        fi
        # На месте пустой строки над тревогами — вход и выход за 7 дней (вариант A).
        if [ $(( ${#UI_BODY[@]} + 1 + ${#UD_PROB[@]} )) -le "$room" ]; then
            if ui_sh_live; then ui_sh_lineA; ui_body "text${UI_US}  ${UI_RS}$UI_P"; else ui_body ""; fi
        fi
        ui_alerts 46 $(( room - ${#UI_BODY[@]} ))
    fi
    ui_menu_info; ui_menu_keys
}

# Окно слишком мало: 40 × 16, подсказка и выход.
ui_scr_small() {
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "окно $UI_COLS × $UI_LINES" "window $UI_COLS × $UI_LINES"; ui_body "title${UI_US}goinstall: $UI_TX${UI_RS}"; ui_body ""
    ut "Нужно не меньше 46 × 24." "Needs at least 46 × 24."; ui_body "text${UI_US}$UI_TX${UI_RS}"
    ut "Растяните окно или уменьшите шрифт." "Enlarge the window or shrink the font."; ui_body "muted${UI_US}$UI_TX${UI_RS}"; ui_body ""
    ut "Без меню: " "Without the menu: "; ui_body "muted${UI_US}$UI_TX${UI_RS}key${UI_US}goinstall --list${UI_RS}"; ui_body ""
    ut " — выход" " — quit"; ui_body "key${UI_US}q${UI_RS}muted${UI_US}$UI_TX${UI_RS}"
}

# ── списки выбора ──────────────────────────────────────────────────────
# Пункты экрана: ключ, подпись, пояснение, тег («✗ препятствий: 2»), действие.
ui_items_clear() { IT_KEY=(); IT_LABEL=(); IT_NOTE=(); IT_NTOK=(); IT_TOK=(); IT_TAG=(); IT_TAGT=(); IT_ACT=(); }
ui_item() {  # ui_item <ключ> <подпись> <действие> [пояснение] [токен пояснения] [тег] [токен тега] [токен подписи]
    IT_KEY+=("$1"); IT_LABEL+=("$2"); IT_ACT+=("$3"); IT_NOTE+=("${4:-}"); IT_NTOK+=("${5:-muted}")
    IT_TAG+=("${6:-}"); IT_TAGT+=("${7:-}"); IT_TOK+=("${8:-}")
}
ui_item_back() { ut "Назад" "Back"; ui_item 0 "$UI_TX" back; }

# Пункты в окне (optLines): «▸ 1  Подпись», пояснение под пунктом или справа.
ui_optlines() {  # ui_optlines <cur> <W> <below 0|1> [ширина подписи]
    local cur="$1" W="$2" below="$3" lw="${4:-0}" i sel lab tok l tg
    for ((i = 0; i < ${#IT_KEY[@]}; i++)); do
        sel=0; [ "$i" = "$cur" ] && sel=1
        UI_SEG=""; _s text " "
        if [ "$sel" = 1 ]; then _s cursor "▸ "; _s cursor "${IT_KEY[$i]}  "; else _s cursor "  "; _s key "${IT_KEY[$i]}  "; fi
        if [ "$sel" = 1 ]; then tok=title; else tok="${IT_TOK[$i]:-name}"; fi
        if [ "$below" = 1 ]; then
            _s "$tok" "${IT_LABEL[$i]}"; tg=0
            if [ -n "${IT_TAG[$i]}" ] && [ $(( ${#IT_LABEL[$i]} + 9 + ${#IT_TAG[$i]} )) -le "$W" ]; then _s text "   "; _s "${IT_TAGT[$i]}" "${IT_TAG[$i]}"; tg=1; fi
            ui_lpush "$UI_SEG" "$sel"
            if [ -n "${IT_NOTE[$i]}" ]; then
                ui_wrap "${IT_NOTE[$i]}" $(( W - 7 ))
                for l in "${UI_WRAP[@]}"; do ui_lpush "text${UI_US}      ${UI_RS}muted${UI_US}${l}${UI_RS}" 0; done
            fi
            if [ -n "${IT_TAG[$i]}" ] && [ "$tg" = 0 ]; then ui_lpush "text${UI_US}      ${UI_RS}${IT_TAGT[$i]}${UI_US}${IT_TAG[$i]}${UI_RS}" 0; fi
        else
            if [ "$lw" -gt 0 ] && [ -n "${IT_NOTE[$i]}" ]; then ui_padr "${IT_LABEL[$i]}" "$lw"; _s "$tok" "$UI_P"; _s "${IT_NTOK[$i]:-muted}" "${IT_NOTE[$i]}"
            else _s "$tok" "${IT_LABEL[$i]}"; fi
            ui_lpush "$UI_SEG" "$sel"
        fi
    done
}
# Пункты без окна (choiceRows): экраны ошибок и «нет ключа».
ui_choicerows() {  # ui_choicerows <cur> [below 0|1]
    local cur="$1" below="${2:-0}" lw i sel tok l
    if [ "$UI_C" -ge 80 ]; then lw=32; else lw=26; fi
    for ((i = 0; i < ${#IT_KEY[@]}; i++)); do
        sel=0; [ "$i" = "$cur" ] && sel=1
        UI_SEG=""; _s text "  "
        if [ "$sel" = 1 ]; then _s cursor "▸ "; _s cursor "${IT_KEY[$i]}  "; tok=title; else _s cursor "  "; _s key "${IT_KEY[$i]}  "; tok="${IT_TOK[$i]:-name}"; fi
        if [ -n "${IT_NOTE[$i]}" ] && [ "$UI_C" -ge 60 ]; then
            # Пояснение не влезает за колонкой — колонка этой строки по подписи.
            l="$lw"; [ $(( 7 + lw + ${#IT_NOTE[$i]} )) -gt "$UI_C" ] && l=$(( ${#IT_LABEL[$i]} + 2 ))
            ui_padr "${IT_LABEL[$i]}" "$l"; _s "$tok" "$UI_P"; _s "${IT_NTOK[$i]:-muted}" "${IT_NOTE[$i]}"
        else _s "$tok" "${IT_LABEL[$i]}"; fi
        if [ "$sel" = 1 ]; then ui_selrow "$UI_SEG"; else ui_body "$UI_SEG"; fi
    done
}
ui_keys_nav() {
    local a b c
    ut "выбрать" "move"; a="$UI_TX"; ut "выбрать" "select"; b="$UI_TX"; ut "цифра" "digit"; c="$UI_TX"; ut "сразу" "jumps"
    local d="$UI_TX"; ut "назад" "back"
    ui_keys_fit "↑↓|$a|" "Enter|$b|" "$c|$d|" "0|$UI_TX|$UI_TX"
}

# ── мастер: ступени ────────────────────────────────────────────────────
# Ступени строятся по продукту: Режим (если есть) → Проверка → Ветка (если
# есть dev) → Установка → Сверка.
ui_wiz_steps() {  # ui_wiz_steps <продукт> → UI_STEPS
    local p="$1"
    UI_STEPS=()
    [ -n "${UD_MODES[$p]:-}" ] && { ut "Режим" "Mode"; UI_STEPS+=("$UI_TX"); }
    ut "Проверка" "Check"; UI_STEPS+=("$UI_TX")
    [ -n "${UD_DEV[$p]:-}" ] && { ut "Ветка" "Branch"; UI_STEPS+=("$UI_TX"); }
    ut "Установка" "Install"; UI_STEPS+=("$UI_TX"); ut "Сверка" "Verify"; UI_STEPS+=("$UI_TX")
}
ui_step_idx() {  # ui_step_idx <ru> <en> → UI_I — номер ступени
    local i; ut "$1" "$2"; UI_I=0
    for ((i = 0; i < ${#UI_STEPS[@]}; i++)); do [ "${UI_STEPS[$i]}" = "$UI_TX" ] && UI_I=$i; done
}
# Строка ступеней над окном: полная от 60 колонок, «Шаг 2 из 5 · …» уже.
ui_steps_row() {  # ui_steps_row <cur> → UI_P
    local cur="$1" i n="${#UI_STEPS[@]}"
    UI_SEG=""
    if [ "$UI_C" -lt 60 ]; then
        ut "Шаг " "Step "; local a="$UI_TX"; ut " из " " of "
        _s muted "  $a$(( cur + 1 ))$UI_TX$n · "; _s title "${UI_STEPS[$cur]}"
        [ $(( cur + 1 )) -lt "$n" ] && _s muted " → ${UI_STEPS[$(( cur + 1 ))]}"
    else
        _s text "  "
        for ((i = 0; i < n; i++)); do
            [ "$i" -gt 0 ] && _s muted " → "
            if [ "$i" -lt "$cur" ]; then _s ok "✓ "; _s text "${UI_STEPS[$i]}"
            elif [ "$i" = "$cur" ]; then _s cursor "● "; _s title "${UI_STEPS[$i]}"
            else _s muted "○ "; _s muted "${UI_STEPS[$i]}"; fi
        done
    fi
    UI_P="$UI_SEG"
}
# Левое окно мастера «УСТАНОВКА» (stepsL): ступени, выбранное, продукт.
ui_build_steps() {  # ui_build_steps <W>  (UI_WP — продукт, UI_WIDX — текущая ступень)
    local W="$1" p="$UI_WP" idx="$UI_WIDX" i n="${#UI_STEPS[@]}" v m b
    ut "Режим" "Mode"; m="$UI_TX"; ut "Ветка" "Branch"; b="$UI_TX"
    ui_lclear
    for ((i = 0; i < n; i++)); do
        UI_SEG=""; _s text " "
        if [ "$i" -lt "$idx" ]; then _s ok "✓ "; elif [ "$i" = "$idx" ]; then _s cursor "● "; else _s muted "○ "; fi
        ui_padr "${UI_STEPS[$i]}" 11
        if [ "$i" = "$idx" ]; then _s title "$UI_P"; elif [ "$i" -lt "$idx" ]; then _s text "$UI_P"; else _s muted "$UI_P"; fi
        v=""
        if [ "${UI_STEPS[$i]}" = "$m" ] && [ -n "${UI_PMODE:-}" ]; then _ui_modename "$UI_PMODE"; v="$UI_TX"; fi
        if [ "${UI_STEPS[$i]}" = "$b" ] && [ -n "${UI_PBRANCH:-}" ]; then v="$UI_PBRANCH"; fi
        _s muted "$v"
        ui_lpush "$UI_SEG" 0
        if [ $(( i + 1 )) -lt "$n" ]; then if [ "$i" -lt "$idx" ]; then ui_lpush "ok${UI_US} │${UI_RS}" 0; else ui_lpush "rule${UI_US} │${UI_RS}" 0; fi; fi
    done
    ui_lpush "" 0
    ui_rep '─' $(( W - 2 )); ui_lpush "rule${UI_US} ${UI_P}${UI_RS}" 0
    ui_lpush "name${UI_US} ${UD_NAME[$p]}${UI_RS}" 0
    _ui_st "$p"
    v="$UI_SW"; [ "${UD_INST[$p]:-0}" = 1 ] && v+=" ${UD_SRV[$p]}"
    ui_lpush "${UI_GT}${UI_US} ${UI_G} ${UI_RS}muted${UI_US}${v}${UI_RS}" 0
}

# ── два окна или одно (shell2) ─────────────────────────────────────────
# Переменные раскладки: SH_LW, SH_LTITLE, SH_LLIST, SH_LBUILD, SH_STEPS46,
# SH_RTITLE, SH_RRIGHT, SH_RRIGHT46, SH_RBUILD, SH_RBUILD46, SH_WIDE.
# Сборщики — имена функций, которые наполняют UI_LS по ширине.
ui_shell2() {
    local i H LW RW p lf rf W main=() mains=() nb H2
    ui_hud
    if [ "$UI_C" -ge 80 ] && [ "${SH_WIDE:-0}" = 0 ]; then
        # На растянутом холсте левое окно получает шестую часть прироста
        # ширины, остальное — правому, где длинные описания и таблицы.
        H=$(( 17 + UI_R - 24 )); LW=$(( SH_LW + (UI_C - 80) / 6 )); RW=$(( UI_C - LW - 2 ))
        "$SH_LBUILD" $(( LW - 2 )); ui_frame2 "$LW" "$H" "$SH_LTITLE" "${SH_LRIGHT:-}"; lf=("${UI_FR[@]}")
        "$SH_RBUILD" $(( RW - 2 )); ui_frame2 "$RW" "$H" "$SH_RTITLE" "${SH_RRIGHT:-}"; rf=("${UI_FR[@]}")
        for ((i = 0; i < H + 2; i++)); do
            if [ "$i" = 0 ]; then p=" "; else p="░"; fi
            ui_body "${lf[$i]}shadow${UI_US}${p}${UI_RS}${rf[$i]}shadow${UI_US}${p}${UI_RS}"
        done
        ui_rep '░' "$LW"; lf="$UI_P"; ui_rep '░' "$RW"
        ui_body "text${UI_US} ${UI_RS}shadow${UI_US}${lf}${UI_RS}text${UI_US} ${UI_RS}shadow${UI_US}${UI_P}${UI_RS}"
    else
        W=$(( UI_C - 1 ))
        [ -n "${SH_STEPS46:-}" ] && ui_body "$SH_STEPS46"
        "${SH_RBUILD46:-$SH_RBUILD}" $(( W - 2 )); main=("${UI_LS[@]}"); mains=("${UI_LSEL[@]}")
        if [ "${SH_LLIST:-0}" = 1 ] && [ "${SH_WIDE:-0}" = 0 ]; then
            if [ "${#main[@]}" -gt 0 ]; then ui_rep '─' $(( W - 4 )); main+=("rule${UI_US} ${UI_P}${UI_RS}"); mains+=(0); fi
            "$SH_LBUILD" $(( W - 2 )); main+=("${UI_LS[@]}"); mains+=("${UI_LSEL[@]}")
        fi
        nb="${#UI_BODY[@]}"
        H2=$(( UI_R - 2 - nb - 3 - ${SH_EXTRA:-0} )); [ "${#main[@]}" -lt "$H2" ] && H2="${#main[@]}"; [ "$H2" -lt 1 ] && H2=1
        UI_LS=("${main[@]}"); UI_LSEL=("${mains[@]}")
        ui_frame2 "$W" "$H2" "$SH_RTITLE" "${SH_RRIGHT46:-}"
        for ((i = 0; i < ${#UI_FR[@]}; i++)); do
            if [ "$i" = 0 ]; then p=" "; else p="░"; fi
            ui_body "${UI_FR[$i]}shadow${UI_US}${p}${UI_RS}"
        done
        ui_rep '░' "$W"; ui_body "text${UI_US} ${UI_RS}shadow${UI_US}${UI_P}${UI_RS}"
    fi
    SH_LRIGHT=""; SH_RBUILD46=""; SH_WIDE=0; SH_STEPS46=""; SH_LLIST=0; SH_RRIGHT=""; SH_RRIGHT46=""; SH_EXTRA=0
}

# ── Д. меню продукта ───────────────────────────────────────────────────
ui_items_product() {  # ui_items_product <продукт>
    local p="$1" a
    ui_items_clear
    if [ "${UD_ST[$p]}" = free ]; then
        # На месте продукта — бесплатная версия из инструкции: первым пунктом
        # pro ставится поверх, её собственное меню отсюда не открываем.
        ut "Поставить ${UD_NAME[$p]} поверх ${UD_STTXT[$p]#* }" "Install ${UD_NAME[$p]} over ${UD_STTXT[$p]#* }"
        ui_item 1 "$UI_TX" wizard "main ${UD_MAIN[$p]:-?}" muted
        ut "Проверить порты" "Check ports"; ui_item 2 "$UI_TX" check
    elif [ "${UD_INST[$p]:-0}" = 1 ]; then
        ut "Открыть меню продукта" "Open the product menu"; ui_item 1 "$UI_TX" openprod "${UD_CMD[$p]}" key
        ut "Обновить или переустановить" "Update or reinstall"; a="$UI_TX"
        if [ "${UD_UPD[$p]:-0}" = 1 ]; then ut " в ${UD_BRANCH[$p]:-main}" " in ${UD_BRANCH[$p]:-main}"; ui_item 2 "$a" wizard "↑ ${UD_UPDV[$p]:-${UD_MAIN[$p]}}$UI_TX" update
        else ut "версия " "version "; local v="$UI_TX${UD_SRV[$p]}"; ut " актуальна" " is current"; ui_item 2 "$a" wizard "$v$UI_TX" muted; fi
        ut "Проверить порты" "Check ports"; ui_item 3 "$UI_TX" check
    else
        _ui_st "$p"; local nt="$UI_GT"; [ "$nt" = muted ] && nt=text
        ut "Установить" "Install"; ui_item 1 "$UI_TX" wizard "$UI_SW" "$nt"
        ut "Проверить порты" "Check ports"; ui_item 2 "$UI_TX" check
    fi
    ui_item_back
}
_ui_b_prod_actions() {  # левое окно «ДЕЙСТВИЯ»: пункты, под чертой — пояснение текущего
    local W="$1" l
    ui_lclear; ui_optlines "$UI_CUR" "$W" 0
    if [ -n "${IT_NOTE[$UI_CUR]:-}" ] && [ "$W" -gt 30 ]; then
        ui_lpush "" 0; ui_rep '─' $(( W - 2 )); ui_lpush "rule${UI_US} ${UI_P}${UI_RS}" 0
        ui_wrap "${IT_NOTE[$UI_CUR]}" $(( W - 3 ))
        for l in "${UI_WRAP[@]}"; do ui_lpush "${IT_NTOK[$UI_CUR]:-muted}${UI_US}  ${l}${UI_RS}" 0; done
    fi
}
_ui_b_prod_card() { MI_KIND=(p); MI_P=("$UI_WP"); ui_arcade_card 0 "$1" 17 1; }
_ui_b_prod_card46() {  # одно окно: описание, строка состояния
    local W="$1" p="$UI_WP" l s
    ui_lclear
    ui_wrap "${UD_DESC[$p]}" $(( W - 2 ))
    for l in "${UI_WRAP[@]}"; do ui_lpush "muted${UI_US} ${l}${UI_RS}" 0; done
    _ui_st "$p"
    if [ "${UD_INST[$p]:-0}" = 1 ]; then s="$UI_SW ${UD_SRV[$p]} · ${UD_BRANCH[$p]:-main}"; else s="$UI_SW · main ${UD_MAIN[$p]}"; fi
    UI_SEG=""; _s "$UI_GT" " $UI_G "; _s text "$s"
    if [ "${UD_UPD[$p]:-0}" = 1 ]; then _s update "  ↑ ${UD_UPDV[$p]:-${UD_MAIN[$p]}}"
    elif [ "${UD_NEW[$p]:-0}" = 1 ]; then ut "новое" "new"; _s new "  ✚ $UI_TX"; fi
    ui_lpush "$UI_SEG" 0
}
ui_scr_product() {  # ui_scr_product <продукт> <cur>
    local p="$1"
    UI_WP="$p"; UI_CUR="$2"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_product "$p"
    MI_KIND=(p); MI_P=("$p"); ui_arcade_card 0 36 17 1
    ut "ДЕЙСТВИЯ" "ACTIONS"
    SH_LW=40; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LLIST=1; SH_LBUILD=_ui_b_prod_actions
    SH_RTITLE="$UI_CT"; SH_RRIGHT="$UI_CR"; SH_RBUILD=_ui_b_prod_card; SH_RBUILD46=_ui_b_prod_card46
    ui_shell2
    ui_keys_nav
}

# ── Ж. вопросы: режим, ветка, подтверждение, язык ──────────────────────
_ui_mode_desc() {  # _ui_mode_desc <продукт> <режим> → UI_TX
    if [ "${UD_CMD[$1]}" = goamnezia ]; then
        case "$2" in
            lazy) ut "только домен, остальное сделает продукт; UDP 443 занят — встанет Semi-pro" "just a domain, the product does the rest; UDP 443 taken — it becomes Semi-pro" ;;
            pro) ut "сайт на TCP 443, AmneziaWG на UDP 443" "site on TCP 443, AmneziaWG on UDP 443" ;;
            lite_site) ut "сайт на TCP 443 и 80, AmneziaWG на своих портах" "site on TCP 443 and 80, AmneziaWG on its own ports" ;;
            *) ut "только VPN, TCP-порты не нужны" "VPN only, no TCP ports needed" ;;
        esac
    elif [ "$2" = pro ]; then ut "домен, сертификат, сайт-маска: 443 и 80" "domain, certificate, mask site: 443 and 80"
    else ut "без домена: только 443" "no domain: 443 only"; fi
}
_ui_b_opts_below() { ui_lclear; ui_optlines "$UI_CUR" "$1" 1; }
_ui_b_steps() { ui_build_steps "$1"; }
_ui_b_prodl() {  # левое окно «ПРОДУКТ» — когда режим выбирают только для проверки
    local W="$1" p="$UI_WP" l v
    ui_lclear
    ui_lpush "name${UI_US} ${UD_NAME[$p]}${UI_RS}" 0
    _ui_st "$p"; v="$UI_SW"; [ "${UD_INST[$p]:-0}" = 1 ] && v+=" ${UD_SRV[$p]}"
    ui_lpush "${UI_GT}${UI_US} ${UI_G} ${UI_RS}muted${UI_US}${v}${UI_RS}" 0
    ui_lpush "" 0
    ui_wrap "${UD_DESC[$p]}" $(( W - 2 )); for l in "${UI_WRAP[@]}"; do ui_lpush "muted${UI_US} ${l}${UI_RS}" 0; done
}
# Режим: пункты как на экране продукта, у каждого — готовность этого режима.
ui_items_mode() {  # ui_items_mode <продукт> — режимы и их итог проверки (UI_MV_<режим>)
    local p="$1" m i=0 bad notes tag tt
    ui_items_clear
    for m in ${UD_MODES[$p]}; do
        i=$(( i + 1 ))
        _ui_modename "$m"; local lab="$UI_TX"; _ui_mode_desc "$p" "$m"
        bad="${UI_MVBAD[$m]:-0}"; notes="${UI_MVNOTES[$m]:-0}"
        if [ "$bad" -gt 0 ]; then ut "препятствий: " "obstacles: "; tag="✗ $UI_TX$bad"; tt=err
        elif [ "$notes" -gt 0 ]; then ut "замечаний: " "notes: "; tag="! $UI_TX$notes"; tt=warn
        else ut "готов" "ready"; tag="✓ $UI_TX"; tt=ok; fi
        _ui_mode_desc "$p" "$m"
        ui_item "$i" "$lab" "mode:$m" "$UI_TX" muted "$tag" "$tt"
    done
    ui_item_back
}
ui_scr_mode() {  # ui_scr_mode <продукт> <cur> [только проверка 0|1]
    local p="$1" only="${3:-0}" di=0 i=0 m
    UI_WP="$p"; UI_CUR="$2"; UI_PMODE=""; UI_PBRANCH=""
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_mode "$p"
    for m in ${UD_MODES[$p]}; do [ "$m" = "${UD_DEFMODE[$p]}" ] && di=$i; i=$(( i + 1 )); done
    _ui_modename "${UD_DEFMODE[$p]}"
    local hint="muted${UI_US}Enter — $(( di + 1 )), ${UI_TX}${UI_RS}"
    ui_wiz_steps "$p"; UI_WIDX=0
    if [ "$only" = 1 ]; then
        ut "ПРОДУКТ" "PRODUCT"; SH_LW=26; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_prodl; SH_STEPS46=""
    else
        ut "УСТАНОВКА" "INSTALL"; SH_LW=26; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_steps
        ui_steps_row 0; SH_STEPS46="$UI_P"
    fi
    ut "РЕЖИМ" "MODE"; SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RRIGHT="$hint"; SH_RRIGHT46="$hint"; SH_RBUILD=_ui_b_opts_below
    ui_shell2
    ui_keys_nav
    UI_DEFCUR=$di
}
ui_scr_branch() {  # ui_scr_branch <продукт> <cur>
    local p="$1" note a
    UI_WP="$p"; UI_CUR="$2"; UI_PBRANCH=""
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    # Стоит с dev — пометки «сейчас стоит» и «новее» у неё, и курсор на ней:
    # Enter не уводит goKaskad pro 3.x с dev на 2.x с main.
    local dr="${UD_DEVREF[$p]:-dev}" on2=0 di=1
    [ "${UD_INST[$p]:-0}" = 1 ] && [ "${UD_BRANCH[$p]:-main}" = "$dr" ] && { on2=1; di=2; }
    ut "стабильная" "stable"; note="$UI_TX"
    if [ "$on2" = 0 ] && [ "${UD_INST[$p]:-0}" = 1 ]; then ut "; сейчас стоит " "; installed now "; note+="$UI_TX${UD_SRV[$p]}"; fi
    if [ "$on2" = 0 ] && [ "${UD_UPD[$p]:-0}" = 1 ]; then ut "; ↑ новее" "; ↑ newer"; note+="$UI_TX"; fi
    ui_items_clear
    ui_item 1 "main ${UD_MAIN[$p]}" branch:main "$note"
    a=$(ref_kind "$dr"); [ -n "$a" ] || { ut "экспериментальная" "experimental"; a="$UI_TX"; }
    if [ "$on2" = 1 ]; then ut "; сейчас стоит " "; installed now "; a+="$UI_TX${UD_SRV[$p]}"
        if [ "${UD_UPD[$p]:-0}" = 1 ]; then ut "; ↑ новее" "; ↑ newer"; a+="$UI_TX"; fi; fi
    ui_item 2 "$dr ${UD_DEV[$p]}" "branch:$dr" "$a"
    ui_item_back
    ui_wiz_steps "$p"; ui_step_idx "Ветка" "Branch"; UI_WIDX=$UI_I
    ut "УСТАНОВКА" "INSTALL"; SH_LW=26; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_steps
    ui_steps_row "$UI_I"; SH_STEPS46="$UI_P"
    local hint="muted${UI_US}Enter — 1, main${UI_RS}"
    [ "$di" = 2 ] && hint="muted${UI_US}Enter — 2, ${dr}${UI_RS}"
    ut "ВЕТКА" "BRANCH"; SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RRIGHT="$hint"; SH_RRIGHT46="$hint"; SH_RBUILD=_ui_b_opts_below
    ui_shell2
    ui_keys_nav
}
_ui_b_confirm() {
    local W="$1" l
    ui_lclear
    ui_wrap "$UI_Q" $(( W - 2 )); for l in "${UI_WRAP[@]}"; do ui_lpush "title${UI_US} ${l}${UI_RS}" 0; done
    ui_lpush "" 0
    ui_optlines "$UI_CUR" "$W" 0
    ui_lpush "" 0
    ut "проверка портов пройдена" "port check passed"; ui_lpush "ok${UI_US} ✓ ${UI_RS}muted${UI_US}${UI_TX}${UI_RS}" 0
}
ui_scr_confirm() {  # ui_scr_confirm <продукт> <cur>  (UI_PBRANCH — выбранная ветка)
    local p="$1" ver a b
    UI_WP="$p"; UI_CUR="$2"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    if [ "$UI_PBRANCH" = "${UD_DEVREF[$p]:-dev}" ]; then ver="${UD_DEV[$p]}"; else ver="${UD_MAIN[$p]}"; fi
    ut "Запустить установщик " "Run the installer of "; a="$UI_TX"; ut "ветка " "branch "
    UI_Q="$a${UD_NAME[$p]} — $UI_TX$UI_PBRANCH${ver:+, $ver}?"
    ui_items_clear; ut "Да" "Yes"; ui_item 1 "$UI_TX" yes; ut "Нет" "No"; ui_item 2 "$UI_TX" no
    ui_wiz_steps "$p"; ui_step_idx "Установка" "Install"; UI_WIDX=$UI_I
    ut "УСТАНОВКА" "INSTALL"; SH_LW=26; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_steps
    ui_steps_row "$UI_I"; SH_STEPS46="$UI_P"
    ut "Да" "Yes"; local hint="muted${UI_US}Enter — 1, ${UI_TX}${UI_RS}"
    ut "ПОДТВЕРЖДЕНИЕ" "CONFIRM"; SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RRIGHT="$hint"; SH_RRIGHT46="$hint"; SH_RBUILD=_ui_b_confirm
    ui_shell2
    ut "да" "yes"; a="$UI_TX"; ut "нет" "no"; ui_keys_fit "1|$a|" "2|$UI_TX|" "Enter|1|1"
}
_ui_b_lang_list() { ui_lclear; ui_optlines "$UI_CUR" "$1" 0; }
_ui_b_lang_info() {
    local W="$1" l
    ui_lclear
    ui_lpush "title${UI_US} Язык / Language${UI_RS}" 0
    if [ "${LANG_CODE:-ru}" = en ]; then ui_lpush "muted${UI_US} Enter — 2, English${UI_RS}" 0; else ui_lpush "muted${UI_US} Enter — 1, Русский${UI_RS}" 0; fi
    ui_lpush "" 0
    ut "Выбор запоминается в /opt/go-installer/.language и больше не спрашивается." "The choice is saved to /opt/go-installer/.language and not asked again."
    ui_wrap "$UI_TX" $(( W - 2 )); for l in "${UI_WRAP[@]}"; do ui_lpush "muted${UI_US} ${l}${UI_RS}" 0; done
}
_ui_b_empty() { ui_lclear; }
ui_scr_lang() {  # ui_scr_lang <cur>
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear; ui_item 1 "Русский" lang:ru; ui_item 2 "English" lang:en; ui_item_back
    SH_LW=30; SH_LTITLE="title${UI_US}ЯЗЫК · LANGUAGE${UI_RS}"; SH_LLIST=1; SH_LBUILD=_ui_b_lang_list
    SH_RTITLE="title${UI_US}ЯЗЫК · LANGUAGE${UI_RS}"; SH_RBUILD=_ui_b_lang_info; SH_RBUILD46=_ui_b_empty
    ui_shell2
    ut "назад" "back"; ui_keys_fit "1|Русский|" "2|English|" "0|$UI_TX|"
}

# ── Е. проверка портов ─────────────────────────────────────────────────
# Строки проверки — массивы UI_PFR_* (порт, статус ok|bad|note|info,
# описание, кто держит), правила — UI_PFU_* (значок, токен, текст).
_ui_pfg() { case "$1" in ok) UI_G='✓'; UI_GT=ok ;; bad) UI_G='✗'; UI_GT=err ;; note) UI_G='!'; UI_GT=warn ;; *) UI_G='·'; UI_GT=muted ;; esac; }
_ui_b_check() {
    local W="$1" i n=0 HW=20 DW g l k
    ui_lclear
    [ "$W" -lt 50 ] && n=1
    DW=$(( W - 13 - HW ))
    if [ "$n" = 0 ]; then
        ut "ПОРТ" "PORT"; ui_padr "$UI_TX" 10; l="$UI_P"; ut "ЧТО ЭТО" "WHAT FOR"; ui_padr "$UI_TX" "$DW"; local a="$UI_P"; ut "КТО ДЕРЖИТ" "HELD BY"
        ui_lpush "muted${UI_US} ${l}  ${a}${UI_TX}${UI_RS}" 0
    fi
    for ((i = 0; i < ${#UI_PFR_PORT[@]}; i++)); do
        _ui_pfg "${UI_PFR_ST[$i]}"
        ui_padr "${UI_PFR_PORT[$i]}" 10
        UI_SEG=""; _s text " $UI_P"; _s "$UI_GT" "$UI_G"; _s text " "
        if [ "$n" = 1 ]; then
            if [ -n "${UI_PFR_H[$i]}" ] && [ "${UI_PFR_ST[$i]}" != ok ]; then
                if [ "${UI_PFR_ST[$i]}" = bad ]; then _s err "${UI_PFR_H[$i]}"; else _s text "${UI_PFR_H[$i]}"; fi
            else _s muted "${UI_PFR_D[$i]}"; fi
        else
            ui_padr "${UI_PFR_D[$i]}" $(( DW - 1 )); _s text "$UI_P "
            case "${UI_PFR_ST[$i]}" in bad) k=err ;; ok) k=muted ;; *) k=text ;; esac
            _s "$k" "${UI_PFR_H[$i]}"
        fi
        ui_lpush "$UI_SEG" 0
    done
    ui_lpush "" 0
    for ((i = 0; i < ${#UI_PFU_TXT[@]}; i++)); do
        ui_wrap "${UI_PFU_TXT[$i]}" $(( W - 4 ))
        for ((k = 0; k < ${#UI_WRAP[@]}; k++)); do
            if [ "$k" = 0 ]; then g="${UI_PFU_G[$i]}"; else g=" "; fi
            ui_lpush "${UI_PFU_T[$i]}${UI_US} ${g} ${UI_RS}text${UI_US}${UI_WRAP[$k]}${UI_RS}" 0
        done
    done
    if [ "${UI_PF_BAD:-0}" -gt 0 ]; then
        ut "Ставить нельзя: препятствий — ${UI_PF_BAD}." "Cannot install: ${UI_PF_BAD} obstacles."
        ui_lpush "err${UI_US} ✗ ${UI_RS}err${UI_US}${UI_TX}${UI_RS}" 0
    elif [ "${UI_PF_NOTES:-0}" -gt 0 ]; then
        ut "Можно ставить: препятствий нет, замечаний — ${UI_PF_NOTES}." "Ready to install: no obstacles, ${UI_PF_NOTES} note(s)."
        ui_lpush "ok${UI_US} ✓ ${UI_RS}title${UI_US}${UI_TX}${UI_RS}" 0
    else
        ut "Можно ставить: препятствий нет." "Ready to install: no obstacles."
        ui_lpush "ok${UI_US} ✓ ${UI_RS}title${UI_US}${UI_TX}${UI_RS}" 0
    fi
    ui_lpush "" 0
    ui_optlines "$UI_CUR" "$W" 0
}
ui_scr_check() {  # ui_scr_check <продукт> <cur> <мастер 0|1>  (UI_PMODE — режим)
    local p="$1" wiz="$3" a
    UI_WP="$p"; UI_CUR="$2"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear
    if [ "$wiz" = 1 ]; then
        if [ "${UI_PF_BAD:-0}" -gt 0 ]; then
            if [ -n "${UD_MODES[$p]:-}" ]; then ut "Выбрать другой режим" "Pick another mode"; ui_item 1 "$UI_TX" back; fi
        else
            if [ -n "${UD_DEV[$p]:-}" ]; then ut "дальше — выбор ветки" "next: branch"; else ut "дальше — подтверждение" "next: confirm"; fi
            a="$UI_TX"; ut "Продолжить" "Continue"; ui_item 1 "$UI_TX" continue "$a"
        fi
    else
        if [ -n "${UD_MODES[$p]:-}" ]; then ut "Проверить другой режим" "Check another mode"; ui_item 1 "$UI_TX" othermode; fi
    fi
    ui_item_back
    ui_wiz_steps "$p"; ui_step_idx "Проверка" "Check"; UI_WIDX=$UI_I
    if [ "$wiz" = 1 ]; then ui_steps_row "$UI_I"; SH_STEPS46="$UI_P"; else SH_STEPS46=""; fi
    UI_SEG=""; _s title "${UD_NAME[$p]}"; ut " · проверка портов" " · port check"; a="$UI_TX"
    if [ -n "${UI_PMODE:-}" ]; then _ui_modename "$UI_PMODE"; a+=" · $UI_TX"; fi
    _s muted "$a"
    SH_RTITLE="$UI_SEG"; SH_RBUILD=_ui_b_check; SH_WIDE=1; SH_RRIGHT46=""
    ui_shell2
    UI_SEG=""
    if [ "$UI_C" -lt 60 ]; then ut "свой · ✗ препятствие · ! замечание" "own · ✗ obstacle · ! note"
    else ut "свободен или свой · ✗ занят, препятствие · ! занят, замечание · · к сведению" "free or own · ✗ taken, obstacle · ! taken, note · · for info"; fi
    _s muted "  ✓ $UI_TX"; UI_INFO="$UI_SEG"
    ui_keys_nav
}

# ── З. итог ────────────────────────────────────────────────────────────
_ui_b_result() {
    local W="$1" p="$UI_WP" a
    ui_lclear
    _R() {  # _R <значок> <токен> <текст> [токен текста]
        local k
        ui_wrap "$3" $(( W - 4 ))
        for ((k = 0; k < ${#UI_WRAP[@]}; k++)); do
            if [ "$k" = 0 ]; then ui_lpush "$2${UI_US} $1 ${UI_RS}${4:-text}${UI_US}${UI_WRAP[$k]}${UI_RS}" 0
            else ui_lpush "$2${UI_US}   ${UI_RS}${4:-text}${UI_US}${UI_WRAP[$k]}${UI_RS}" 0; fi
        done
    }
    if [ -n "${UI_PC_ST:-}" ]; then
        # Код установщика, не встал, бесплатный на месте, не та версия —
        # словами installer_verdict.
        if [ "$UI_PC_ST" = err ]; then _R '✗' err "$UI_PC_TX" title; else _R '!' warn "$UI_PC_TX" title; fi
        # Вывод установщика остался в основном буфере терминала, под
        # «Аркадой» его не видно. Своего журнала установки ни один продукт
        # не ведёт (их журналы — о работе, а не об установке), пути нет.
        ut "Вывод установщика — в терминале над строкой «Нажмите Enter — сверка итога»: он виден после выхода из goinstall. Повторить: «Обновить» в меню продукта или ${UD_CMD[$p]}" "The installer output is in the terminal above “Press Enter — verify the result”: it shows after you quit goinstall. To retry: “Update” in the product menu or ${UD_CMD[$p]}"
        _R ' ' muted "$UI_TX" muted
    elif [ "${UI_MISM:-0}" = 1 ]; then
        ut "Ветка не сменилась: ${UD_NAME[$p]} стоит с ветки ${UD_BRANCH[$p]}, а выбрана ${UI_PBRANCH}" "Branch did not change: ${UD_NAME[$p]} runs from branch ${UD_BRANCH[$p]}, but ${UI_PBRANCH} was chosen"
        _R '!' warn "$UI_TX" title
        ut "Повторите установку или смените ветку в меню продукта: ${UD_CMD[$p]}" "Run the install again or switch the branch in the product menu: ${UD_CMD[$p]}"
        _R ' ' muted "$UI_TX" muted
    else
        ut "Проверено: ${UD_NAME[$p]} стоит с ветки ${UD_BRANCH[$p]}, версия ${UD_SRV[$p]}" "Verified: ${UD_NAME[$p]} runs from branch ${UD_BRANCH[$p]}, version ${UD_SRV[$p]}"
        _R '✓' ok "$UI_TX" title
    fi
    if [ -n "${UI_LAZYMODE:-}" ]; then
        ui_lpush "" 0
        _ui_modename "$UI_LAZYMODE"; a="$UI_TX"
        ut "Ленивый pro встал в режиме $a" "Lazy pro ended up in $a mode"; _R '!' warn "$UI_TX" title
        if [ "$UI_LAZYMODE" = lite_site ]; then
            ut "UDP 443 был занят. Режим меняется в меню продукта: ${UD_CMD[$p]}" "UDP 443 was taken. Change the mode in the product menu: ${UD_CMD[$p]}"
            _R ' ' muted "$UI_TX" muted
        fi
    fi
    ui_lpush "" 0
    ui_optlines "$UI_CUR" "$W" 0
}
ui_scr_result() {  # ui_scr_result <продукт> <cur>  (UI_PBRANCH, UI_MISM, UI_LAZYMODE)
    local p="$1"
    UI_WP="$p"; UI_CUR="$2"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear
    ut "Открыть меню продукта" "Open the product menu"; ui_item 1 "$UI_TX" openprod "${UD_CMD[$p]}" key
    ut "В главное меню" "Main menu"; ui_item 0 "$UI_TX" root
    ui_wiz_steps "$p"; UI_WIDX="${#UI_STEPS[@]}"
    ut "УСТАНОВКА" "INSTALL"; SH_LW=26; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_steps
    ui_steps_row $(( ${#UI_STEPS[@]} - 1 )); SH_STEPS46="$UI_P"
    # «Не встал» — только если продукта нет; код ≠0 у стоящего (обновление
    # не закончено, стоит прежний) — словами о коде.
    if [ "${UI_PC_ST:-}" = err ] && [ "${UI_PC_RC:-0}" != 0 ] && [ -n "${UI_PC_HAVE:-}" ]; then
        ut "установщик вышел с кодом ${UI_PC_RC}" "installer exited with code ${UI_PC_RC}"; SH_RRIGHT="err${UI_US}✗ ${UI_TX}${UI_RS}"
    elif [ "${UI_PC_ST:-}" = err ]; then ut "не встал" "failed"; SH_RRIGHT="err${UI_US}✗ ${UI_TX}${UI_RS}"
    elif [ "${UI_MISM:-0}" = 1 ] || [ "${UI_PC_ST:-}" = warn ]; then ut "замечание" "note"; SH_RRIGHT="warn${UI_US}! ${UI_TX}${UI_RS}"
    else ut "готово" "done"; SH_RRIGHT="ok${UI_US}✓ ${UI_TX}${UI_RS}"; fi
    ut "СВЕРКА" "VERIFY"; SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RBUILD=_ui_b_result
    ui_shell2
    ui_keys_nav
}

# ── И. карта портов ────────────────────────────────────────────────────
# Группы: UI_PG_NAME[] и строки UI_PG_ROWS[] — «порт|процесс|что это;…».
_ui_b_ports_list() { ui_lclear; ui_optlines "$UI_CUR" "$1" 0 $(( $1 - 9 )); }
_ui_b_ports_group() {
    local W="$1" g n=0 row port proc what l
    ui_lclear
    [ "$W" -lt 50 ] && n=1
    g="${UI_PG_CUR:-0}"
    if [ "$n" = 0 ]; then
        ut "ПОРТ" "PORT"; ui_padr "$UI_TX" 11; l="$UI_P"; ut "ПРОЦЕСС" "PROCESS"; ui_padr "$UI_TX" 12; local a="$UI_P"; ut "ЧТО ЭТО" "WHAT FOR"
        ui_lpush "muted${UI_US} ${l}${a}${UI_TX}${UI_RS}" 0
    fi
    local IFS_OLD="$IFS"; IFS=';'
    for row in ${UI_PG_ROWS[$g]}; do
        IFS='|' read -r port proc what <<<"$row"
        # Пробел после процесса — всегда: обрезанное «systemd-res…» слипалось с «что это».
        if [ "$n" = 1 ]; then ui_padr "$port" 10; l="$UI_P"; ui_padr "$proc" 8; else ui_padr "$port" 11; l="$UI_P"; ui_padr "$proc" 11; fi; UI_P+=" "
        ui_lpush "text${UI_US} ${l}${UI_RS}key${UI_US}${UI_P}${UI_RS}muted${UI_US}${what}${UI_RS}" 0
    done
    IFS="$IFS_OLD"
}
ui_scr_ports() {  # ui_scr_ports <cur>
    local i
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear
    for ((i = 0; i < ${#UI_PG_NAME[@]}; i++)); do
        local rows="${UI_PG_ROWS[$i]}" c=1; rows="${rows//[!;]/}"; c=$(( ${#rows} + 1 ))
        ui_item "$(( i + 1 ))" "${UI_PG_NAME[$i]}" "group:$i" "$c"
    done
    ui_item_back
    UI_PG_CUR="$UI_CUR"; [ "$UI_PG_CUR" -ge "${#UI_PG_NAME[@]}" ] && UI_PG_CUR=$(( ${#UI_PG_NAME[@]} - 1 ))
    ut "КТО ДЕРЖИТ" "HOLDERS"; SH_LW=28; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LLIST=1; SH_LBUILD=_ui_b_ports_list
    SH_RTITLE="title${UI_US}${UI_PG_NAME[$UI_PG_CUR]}${UI_RS}"; SH_RRIGHT="muted${UI_US}goinstall --ports${UI_RS}"; SH_RBUILD=_ui_b_ports_group
    ui_shell2
    local a b; ut "выбрать" "move"; a="$UI_TX"; ut "выбрать" "select"; b="$UI_TX"; ut "цифра" "digit"; local c="$UI_TX"; ut "сразу" "jumps"; local d="$UI_TX"; ut "назад" "back"
    ui_keys_fit "↑↓|$a|" "Enter|$b|" "$c|$d|" "0|$UI_TX|$UI_TX"
}

# ── К. ключ доступа ────────────────────────────────────────────────────
_ui_b_key_list() { ui_lclear; ui_optlines "$UI_CUR" "$1" 0; }
_ui_b_key_card() {
    local W="$1" l
    ui_lclear
    # «Сохранён … 0600» — только когда файл есть: ключ из окружения до
    # проверки живёт лишь в памяти.
    if token_saved; then
        ut "сохранён" "saved"; ui_lpush "ok${UI_US} ● ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" 0
        ui_lpush "muted${UI_US}   ${TOKEN_FILE:-/opt/go-installer/token} · 0600${UI_RS}" 0
    else
        ut "не сохранён — только на этот запуск" "not saved — for this run only"; ui_lpush "warn${UI_US} ○ ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" 0
    fi
    ui_lpush "" 0
    if [ -n "${UI_KEYCHECKING:-}" ]; then
        ut "проверяю 6 репозиториев…" "checking 6 repositories…"; ui_lpush "cursor${UI_US} ${UI_SPIN:-⠋} ${UI_RS}muted${UI_US}${UI_TX}${UI_RS}" 0
    elif [ -n "${UD_KEYDENIED:-}" ]; then
        ut "открывает ${UD_KEYOK:-5} из 6" "opens ${UD_KEYOK:-5} of 6"; ui_lpush "warn${UI_US} ! ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" 0
        ut "нет доступа" "no access"; ui_lpush "warn${UI_US}   ${UD_KEYDENIED} — ${UI_TX}${UI_RS}" 0
        ui_lpush "" 0
        ut "Возьмите свежий ключ в «anten-ka club», ветка «goinstall», и введите его пунктом 2." "Get a fresh key in “anten-ka club”, topic “goinstall”, and enter it via item 2."
        ui_wrap "$UI_TX" $(( W - 4 )); for l in "${UI_WRAP[@]}"; do ui_lpush "muted${UI_US}   ${l}${UI_RS}" 0; done
    elif [ "${TOKEN_STATUS:-}" = ok ]; then
        ut "открывает 6 из 6" "opens 6 of 6"; ui_lpush "ok${UI_US} ✓ ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" 0
        ut "проверен в " "checked at "; ui_lpush "muted${UI_US}   ${UI_TX}${UD_KEYAT:-$UD_SVED}${UI_RS}" 0
    else
        # Проверки не было или она не дошла — «открывает 6 из 6» было бы выдумкой.
        case "${TOKEN_STATUS:-}" in
            nonet)   ut "не проверен: GitHub недоступен" "not checked: GitHub is unreachable" ;;
            limited) ut "не проверен: лимит GitHub" "not checked: GitHub rate limit" ;;
            *)       ut "не проверен" "not checked" ;;
        esac
        ui_lpush "warn${UI_US} ! ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" 0
    fi
}
token_saved() { [ -s "${TOKEN_FILE:-}" ]; }
ui_scr_key() {  # ui_scr_key <cur>
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear
    ut "Проверить ключ" "Check the key"; ui_item 1 "$UI_TX" keycheck
    ut "Ввести новый ключ" "Enter a new key"; ui_item 2 "$UI_TX" keyinput
    ut "Удалить ключ" "Forget the key"; ui_item 3 "$UI_TX" keyforget "goinstall --key forget"
    ui_item_back
    ut "ДЕЙСТВИЯ" "ACTIONS"; SH_LW=30; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LLIST=1; SH_LBUILD=_ui_b_key_list
    if [ -n "${UD_KEYDENIED:-}" ]; then SH_RRIGHT="warn${UI_US}! ${UD_KEYOK:-5}/6${UI_RS}"; else SH_RRIGHT="ok${UI_US}✓ 6/6${UI_RS}"; fi
    ut "КЛЮЧ ДОСТУПА" "ACCESS KEY"; SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RBUILD=_ui_b_key_card
    ui_shell2
    ui_keys_nav
}

# ── рамка без окон (box) — экран «нет ключа» и сводка при входе ────────
# ui_box <заголовок-сегменты> <правая метка-сегменты или ""> <низ-сегменты>;
# строки внутри — UI_BX[] («SEP» — пустая строка-разделитель).
ui_box() {
    local title="$1" right="$2" bottom="$3" Wb=$(( UI_C - 1 )) iw top tr n l bl
    iw=$(( Wb - 4 ))
    top="grad${UI_US}╔═ ${UI_RS}${title}grad${UI_US} ${UI_RS}"
    if [ -n "$right" ]; then tr="grad${UI_US} ${UI_RS}${right}grad${UI_US} ═╗${UI_RS}"; else tr="grad${UI_US}═╗${UI_RS}"; fi
    ui_len "$top"; n=$UI_N; ui_len "$tr"
    if [ $(( Wb - n - UI_N )) -lt 1 ]; then tr="grad${UI_US}═╗${UI_RS}"; ui_len "$tr"; fi
    ui_rep '═' $(( Wb - n - UI_N ))
    ui_body "${top}grad${UI_US}${UI_P}${UI_RS}${tr}text${UI_US} ${UI_RS}"
    for l in "${UI_BX[@]}"; do
        if [ "$l" = SEP ]; then ui_rep ' ' $(( Wb - 2 )); ui_body "grad${UI_US}║${UI_P}║${UI_RS}shadow${UI_US}░${UI_RS}"; continue; fi
        ui_fit "$l" "$iw"; printf -v UI_P '%*s' $(( iw - UI_FITN )) ''
        ui_body "grad${UI_US}║ ${UI_RS}${UI_FIT}text${UI_US}${UI_P}${UI_RS}grad${UI_US} ║${UI_RS}shadow${UI_US}░${UI_RS}"
    done
    bl="grad${UI_US}╚═ ${UI_RS}${bottom}grad${UI_US} ${UI_RS}"
    ui_len "$bl"; ui_rep '═' $(( Wb - UI_N - 1 ))
    ui_body "${bl}grad${UI_US}${UI_P}${UI_RS}grad${UI_US}╝${UI_RS}shadow${UI_US}░${UI_RS}"
    ui_rep '░' "$Wb"; ui_body "text${UI_US} ${UI_RS}shadow${UI_US}${UI_P}${UI_RS}"
}
ui_scr_nokey() {  # ui_scr_nokey <cur>
    local l
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_main_title; ui_hdr "$UI_MT" ""; ui_body ""
    UI_BX=()
    if [ "${UI_KEYBAD:-0}" = 1 ]; then ut "Сохранённый ключ больше не работает: GitHub его не принимает." "The saved key no longer works: GitHub rejects it."; UI_BX+=("text${UI_US} ${UI_RS}err${UI_US}${UI_TX}${UI_RS}"); fi
    ut "Репозитории продуктов закрытые: без ключа не скачивается ни один." "Product repositories are private: nothing downloads without a key."
    UI_BX+=("text${UI_US} ${UI_RS}text${UI_US}${UI_TX}${UI_RS}"); UI_BX+=("")
    ut "Ключ на чтение выдаётся подписчикам в закрытой группе «anten-ka club», в ветке «goinstall». Подписка: boosty.to/anten-ka" "A read key is given to subscribers in the private “anten-ka club” group, topic “goinstall”. Subscription: boosty.to/anten-ka"
    ui_wrap "$UI_TX" $(( UI_C - 6 )); for l in "${UI_WRAP[@]}"; do UI_BX+=("text${UI_US} ${UI_RS}muted${UI_US}${l}${UI_RS}"); done
    ut "Нужен ключ доступа" "An access key is needed"
    ui_box "warn${UI_US}${UI_TX}${UI_RS}" "" "key${UI_US}goinstall --key set${UI_RS}"
    ui_body ""
    # Решение заказчика 14.10: без ключа — как в нумерованном меню: проверка
    # портов, карта портов, компоненты работают, установка просит ключ.
    ui_items_clear; ut "Ввести ключ" "Enter the key"; ui_item 1 "$UI_TX" keyinput
    # Пояснение целиком не влезает за подписью (7 — отступ, курсор, номер;
    # 2 — промежуток) — короткое, но с тем же смыслом: обрезанное «…; устан…»
    # теряло «после ключа».
    local nt lb
    ut "Продолжить без ключа" "Continue without a key"; lb="$UI_TX"
    ut "карта портов и проверка; установка — после ключа" "port map and check; install after a key"; nt="$UI_TX"
    if [ $(( 7 + $(str_len "$lb") + 2 + $(str_len "$nt") )) -gt "$UI_C" ]; then ut "установка — после ключа" "install after a key"; nt="$UI_TX"; fi
    ui_item 2 "$lb" nokeygo "$nt"
    ut "Выход" "Quit"; ui_item 0 "$UI_TX" quit
    ui_choicerows "$UI_CUR"
    ui_keys_nav
}
# Установка и обновление без ключа не идут: ключа нет — экран ввода ключа, а
# после него — снова мастер этого продукта. rc 1 — ушли за ключом.
ui_need_key() {
    [ -n "${TOKEN:-}" ] && return 0
    prod_needs_token "${PRODUCTS[$UI_WP]}" || return 0
    UI_KEYTHEN="$UI_WP"; UI_KEYBUF=""; UI_KEYST=""; UI_INPUT=1; ui_go keyinput 0
    ut "Для установки нужен ключ доступа" "Installing needs an access key"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 6 ))
    return 1
}
# Ввод ключа: символы звёздочками, Enter — проверить, Esc — назад.
ui_scr_keyinput() {  # ui_scr_keyinput <сколько введено> [состояние: checking|ok|bad]
    local n="$1" st="${2:-}"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "Ключ доступа" "Access key"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" ""; ui_body ""
    ut "Вставьте ключ и нажмите Enter." "Paste the key and press Enter."; ui_body "text${UI_US}  ${UI_TX}${UI_RS}"
    ut "Он сохранится в /opt/go-installer/token, режим 0600." "It is saved to /opt/go-installer/token, mode 0600."; ui_body "muted${UI_US}  ${UI_TX}${UI_RS}"; ui_body ""
    [ "$n" -gt $(( UI_C - 12 )) ] && n=$(( UI_C - 12 ))
    ui_rep '*' "$n"; ut "ключ: " "key: "; ui_body "muted${UI_US}  ${UI_TX}${UI_RS}text${UI_US}${UI_P}${UI_RS}cursor${UI_US}█${UI_RS}"; ui_body ""
    case "$st" in
        checking) ut "проверяю…" "checking…"; ui_body "cursor${UI_US}  ${UI_SPIN:-⠋} ${UI_RS}muted${UI_US}${UI_TX}${UI_RS}" ;;
        ok) ut "ключ подошёл: открывает 6 из 6" "the key works: opens 6 of 6"; ui_body "ok${UI_US}  ✓ ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" ;;
        bad) ut "GitHub этот ключ не принял. Проверьте, что скопирован он целиком." "GitHub rejected this key. Check that it was copied in full."; ui_body "err${UI_US}  ✗ ${UI_RS}text${UI_US}${UI_TX}${UI_RS}" ;;
    esac
    local a; ut "сохранить" "save"; a="$UI_TX"; ut "назад" "back"; ui_keys_fit "Enter|$a|" "Esc|$UI_TX|$UI_TX"
}

# ── К. опрос не удался ─────────────────────────────────────────────────
ui_scr_err() {  # ui_scr_err <github|rate> <cur>
    local gh=0 l tx
    [ "$1" = github ] && gh=1
    UI_CUR="$2"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_main_title; ui_hdr "$UI_MT" ""; ui_body ""
    if [ "$gh" = 1 ]; then ut "GitHub недоступен" "GitHub is unreachable"; ui_body "err${UI_US}  ✗ ${UI_RS}title${UI_US}${UI_TX}${UI_RS}"
    else ut "Лимит запросов к GitHub исчерпан, повтор в ${UI_RESET:-?}" "GitHub rate limit reached, retry at ${UI_RESET:-?}"; ui_body "warn${UI_US}  ! ${UI_RS}title${UI_US}${UI_TX}${UI_RS}"; fi
    ui_body ""
    local L=()
    if [ "$gh" = 1 ]; then
        ut "Новые версии узнать не удалось. Меню откроется со сведениями от ${UD_SVED}." "Could not fetch new versions. The menu opens with data as of ${UD_SVED}."; L+=("$UI_TX")
        if [ -n "${UI_NETRC:-}" ]; then
            L+=("$(bi "Причина" "Cause"): $(gh_net_reason "$UI_NETRC"). $(bi "Попыток на каждый запрос: ${GH_TRIES}, ожидание до ${GH_MT} с." "Attempts per request: ${GH_TRIES}, waiting up to ${GH_MT} s each.")")
        else
            ut "Проверьте сеть сервера: curl -I https://api.github.com" "Check the server network: curl -I https://api.github.com"; L+=("$UI_TX")
        fi
    else
        ut "Ответили ${UI_POLLOK:-5} из 8. Остальное меню покажет по сведениям от ${UD_SVED}." "${UI_POLLOK:-5} of 8 answered. The rest shows data as of ${UD_SVED}."; L+=("$UI_TX")
        ut "В ${UI_RESET:-?} goinstall спросит GitHub сам." "At ${UI_RESET:-?} goinstall asks GitHub again by itself."; L+=("$UI_TX")
    fi
    for tx in "${L[@]}"; do ui_wrap "$tx" $(( UI_C - 6 )); for l in "${UI_WRAP[@]}"; do ui_body "text${UI_US}    ${l}${UI_RS}"; done; done
    ui_body ""
    ui_items_clear
    ut "Открыть меню со сведениями от ${UD_SVED}" "Open the menu with data as of ${UD_SVED}"; ui_item 1 "$UI_TX" root
    ut "Повторить опрос" "Retry the poll"; ui_item 2 "$UI_TX" retry
    ut "Выход" "Quit"; ui_item 0 "$UI_TX" quit
    ui_choicerows "$UI_CUR"
    ui_keys_nav
}

# ── В. заставка с опросом GitHub ───────────────────────────────────────
# Строки опроса: UI_PI_NAME[], UI_PI_RES[] (что ответил), UI_PI_TOK[],
# UI_PI_ST[] (wait|run|done|fail). Шкала — ответившие из восьми.
ui_scr_splash() {
    local n=0 i c r s ch up face row side done=0 st g res
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    [ "$UI_C" -lt 60 ] && n=1
    local GO=('▄██████▄  ▄██████▄' '██        ██    ██' '██  ████  ██    ██' '▀██████▀  ▀██████▀')
    local SPEED=('      ' '  ════' '══════' ' ═════' '      ')
    local SIDE=()
    SIDE[0]=""; SIDE[1]="title${UI_US}goInstaller ${UI_RS}muted${UI_US}${UD_VER}${UI_RS}"
    if [ "$n" = 1 ]; then ut "установщик серии go" "go series installer"; else ut "установщик продуктов серии go" "installer for the go series"; fi
    SIDE[2]="muted${UI_US}${UI_TX}${UI_RS}"
    if [ "$n" = 1 ]; then SIDE[3]="muted${UI_US}${UD_HOST}${UI_RS}"; else SIDE[3]="muted${UI_US}${UD_HOST} · ${UD_OS}${UI_RS}"; fi
    SIDE[4]=""
    for ((r = 0; r <= 4; r++)); do
        UI_SEG=""; _s text " "
        if [ "$n" = 0 ]; then _s grad "${SPEED[$r]}"; else _s text " "; fi
        local prev="" run=""
        for ((c = 0; c <= 18; c++)); do
            ch=""; [ "$r" -lt 4 ] && ch="${GO[$r]:$c:1}"
            if [ -n "$ch" ] && [ "$ch" != " " ]; then face="logo$r"; s="$ch"
            else
                up=" "; [ "$r" -gt 0 ] && [ "$c" -gt 0 ] && up="${GO[$(( r - 1 ))]:$(( c - 1 )):1}"
                if [ -n "$up" ] && [ "$up" != " " ]; then face=shade; if [ "$r" = 4 ]; then s='▀'; else s='▓'; fi
                else face=text; s=' '; fi
            fi
            if [ "$face" = "$prev" ]; then run+="$s"; else [ -n "$prev" ] && _s "$prev" "$run"; prev="$face"; run="$s"; fi
        done
        _s "$prev" "$run"; _s text "   "
        ui_body "$UI_SEG${SIDE[$r]}"
    done
    ui_body ""
    for st in "${UI_PI_ST[@]}"; do case "$st" in done|fail) done=$(( done + 1 )) ;; esac; done
    ut "  Опрос GitHub  " "  GitHub poll   "; UI_SEG=""; _s text "$UI_TX"
    ui_bar $(( done * 1000 / 8 )) $(( n ? 14 : 24 )) cursor; UI_SEG+="$UI_BAR"
    ut " из 8" " of 8"; _s muted "  $done$UI_TX"; ui_body "$UI_SEG"
    ui_body ""
    for ((i = 0; i < ${#UI_PI_NAME[@]}; i++)); do
        case "${UI_PI_ST[$i]}" in
            done) g='✓'; s=ok; res="${UI_PI_RES[$i]}"; r="${UI_PI_TOK[$i]:-text}" ;;
            fail) g='✗'; s=err
                  if [ -n "${UI_PI_RES[$i]:-}" ]; then UI_TX="${UI_PI_RES[$i]}"
                  elif [ "$UI_POLLERR" = rate ]; then ut "403: лимит запросов" "403: rate limit"; else ut "нет ответа" "no answer"; fi; res="$UI_TX"; r=err ;;
            run)  g="${UI_SPIN:-⠋}"; s=cursor; ut "спрашиваю…" "asking…"; res="$UI_TX"; r=muted ;;
            *)    g='·'; s=muted; ut "ждёт" "queued"; res="$UI_TX"; r=muted ;;
        esac
        ui_padr "${UI_PI_NAME[$i]}" $(( n ? 15 : 17 ))
        ui_body "text${UI_US}  ${UI_RS}${s}${UI_US}${g}${UI_RS}name${UI_US} ${UI_P}${UI_RS}${r}${UI_US}${res}${UI_RS}"
    done
    if [ -n "${UI_PI_NOTE:-}" ]; then
        # Что происходит и почему — пока опрос ещё идёт.
        local nl
        ui_body ""
        ui_wrap "$UI_PI_NOTE" $(( UI_C - 6 )); for nl in "${UI_WRAP[@]}"; do ui_body "warn${UI_US}  ${nl}${UI_RS}"; done
    fi
    if [ "$done" -lt 8 ]; then
        local a; ut "любая клавиша" "any key"; a="$UI_TX"; ut "пропустить, опрос идёт дальше" "skip, polling continues"; local b="$UI_TX"; ut "пропустить" "skip"
        ui_keys_fit "$a|$b|$UI_TX"
    else ut "в меню" "to the menu"; local a="$UI_TX"; ut "меню" "menu"; ui_keys_fit "Enter|$a|$UI_TX"; fi
}

# ── А. сводка при входе ────────────────────────────────────────────────
# Новое (UD_NEWS: «значок|токен|имя|версии|что») и замечания UD_PROB; всё
# тихо — две строки без рамки. UD_NINST — сколько продуктов стоит.
ui_summary() {
    local n=0 u g tk nm vv what sved p name msg short step sev
    [ "$UI_C" -lt 60 ] && n=1
    ut "сведения от " "data as of "; sved="$UI_TX$UD_SVED"
    if [ "${#UD_NEWS[@]}" -eq 0 ] && [ "${#UD_PROB[@]}" -eq 0 ] && [ -z "${UD_SHOFF:-}" ]; then
        UI_SEG=""; _s ok "✓ "; ut "goInstaller: всё актуально" "goInstaller: all up to date"; _s text "$UI_TX"
        if [ "$n" = 0 ]; then ui_plural "${UD_NINST:-0}" продукт продукта продуктов product products; ut ", $UI_TX, проблем нет" ", $UI_TX, no problems"; _s muted "$UI_TX"; fi
        ui_body "$UI_SEG"
        [ "${UD_SH:-}" = A ] && _shield_sum_quiet
        UI_SEG=""; _s muted "  $sved · "; _s key "goinstall"; if [ "$n" = 1 ]; then ut " — меню" " — menu"; else ut " — открыть меню" " — open the menu"; fi; _s muted "$UI_TX"
        ui_body "$UI_SEG"
        return 0
    fi
    UI_BX=()
    for u in "${UD_NEWS[@]}"; do
        IFS='|' read -r g tk nm vv what <<<"$u"
        UI_SEG=""
        if [ "$n" = 1 ]; then _s "$tk" "$g"; ui_padr "$nm" 15; _s name " $UI_P"; _s "$tk" "$vv"
        else _s "$tk" " $g"; ui_padr "$nm" 17; _s name " $UI_P"; ui_padr "$vv" 20; _s "$tk" "$UI_P"; _s muted "$what"; fi
        UI_BX+=("$UI_SEG")
    done
    if [ "${#UD_PROB[@]}" -gt 0 ]; then
        [ "${#UD_NEWS[@]}" -gt 0 ] && UI_BX+=(SEP)
        for p in "${UD_PROB[@]}"; do
            IFS='|' read -r name msg short step sev <<<"$p"
            case "$sev" in err) g='✗'; tk=err ;; ok) g='✓'; tk=ok ;; *) g='!'; tk=warn ;; esac
            if [ "$n" = 1 ]; then
                UI_BX+=("${tk}${UI_US}${g}${UI_RS}text${UI_US} ${short}${UI_RS}")
                UI_BX+=("muted${UI_US}  → ${UI_RS}key${UI_US}${step}${UI_RS}")
            else
                ui_padr "$name" 17
                UI_BX+=("${tk}${UI_US} ${g}${UI_RS}name${UI_US} ${UI_P}${UI_RS}text${UI_US}${msg}${UI_RS}muted${UI_US} → ${UI_RS}key${UI_US}${step}${UI_RS}")
            fi
        done
        ut "диск ${UD_DISK} % · память ${UD_MEM} % · нагрузка ${UD_LOAD}" "disk ${UD_DISK} % · memory ${UD_MEM} % · load ${UD_LOAD}"
        if [ "$n" = 1 ]; then UI_BX+=("muted${UI_US}${UI_TX}${UI_RS}"); else UI_BX+=("text${UI_US} ${UI_RS}muted${UI_US}${UI_TX}${UI_RS}"); fi
    fi
    if [ -n "${UD_SH:-}" ]; then
        [ "${#UI_BX[@]}" -gt 0 ] && UI_BX+=(SEP)
        _shield_sum_box
    fi
    local right bottom
    if [ "$n" = 1 ]; then right="muted${UI_US}${UD_SVED}${UI_RS}"; else right="muted${UI_US}${sved}${UI_RS}"; fi
    if [ "$n" = 1 ]; then ut " — меню" " — menu"; else ut " — открыть меню" " — open the menu"; fi
    bottom="key${UI_US}goinstall${UI_RS}muted${UI_US}${UI_TX}${UI_RS}"
    ui_box "title${UI_US}goInstaller${UI_RS}muted${UI_US} · ${UD_HOST}${UI_RS}" "$right" "$bottom"
}
# Значок в приглашении: [go ↑2 ✚1 !2] — сколько обновлений, нового, замечаний.
ui_badge() {
    local u nu=0 nn=0 np=0
    for u in "${UD_NEWS[@]}"; do case "$u" in '↑|'*) nu=$(( nu + 1 )) ;; '✚|'*) nn=$(( nn + 1 )) ;; esac; done
    # «✓ Ubuntu обновлена» — сведение, а не замечание.
    for u in ${UD_PROB[@]+"${UD_PROB[@]}"}; do case "$u" in *'|ok') ;; *) np=$(( np + 1 )) ;; esac; done
    [ -n "${UD_SHOFF:-}" ] && np=$(( np + 1 ))
    UI_SEG=""
    if [ $(( nu + nn + np )) -gt 0 ]; then
        _s muted " [go"; [ "$nu" -gt 0 ] && _s update " ↑$nu"; [ "$nn" -gt 0 ] && _s new " ✚$nn"; [ "$np" -gt 0 ] && _s warn " !$np"; _s muted "]"
    fi
    UI_BADGE="$UI_SEG"
}
# Экран входа целиком — как в макете: строка sshd, сводка, приглашение.
ui_scr_login() {  # ui_scr_login [отсчёт: сколько осталось, мс]
    local rem="${1:-}" n=0
    [ "$UI_C" -lt 60 ] && n=1
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_body "text${UI_US}${UI_LASTLOGIN:-}${UI_RS}"; ui_body ""
    ui_summary
    ui_body ""
    if [ -n "$rem" ]; then
        UI_SEG=""; _s text "  "; _s key "Enter"
        if [ "$n" = 1 ]; then ut " — goinstall · другая клавиша — консоль" " — goinstall · other key — shell"; else ut " — открыть goinstall · любая другая клавиша — в консоль" " — open goinstall · any other key — shell"; fi
        _s muted "$UI_TX"; ui_body "$UI_SEG"
        UI_SEG=""; _s text "  "; ui_bar $(( rem / 5 )) $(( n ? 20 : 24 )) cursor; UI_SEG+="$UI_BAR"; ut " с" " s"; _s muted "  $(( (rem + 999) / 1000 ))$UI_TX"
        ui_body "$UI_SEG"
    else
        ui_badge
        ui_body "text${UI_US}root@${UD_HOST}${UI_RS}${UI_BADGE}text${UI_US}:~# ${UI_RS}cursor${UI_US}█${UI_RS}"
    fi
}

# ── живые данные ───────────────────────────────────────────────────────
# Системные службы продукта: что показывать в карточке «СЛУЖБЫ».
prod_units() {
    case "$1" in
        govless)    printf 'x-ui nginx' ;;
        gotelegram) printf 'telemt' ;;
        godns)      printf 'dnsdist' ;;
        gowarp)     printf 'warp-svc warp-bot' ;;
        goamnezia)  printf 'goamnezia-admin' ;;
        *)          printf '' ;;
    esac
}
# Состояние службы продукта: run — работает; down — включена, но не
# работает (сбой); off — стоит выключенной (решение человека, не сбой);
# none — на машине её нет. prod_units — все службы продукта, а стоят не все:
# goWARP pro ставит warp-svc только для 3X-UI, warp-bot — только с ботом. До
# 1.0.8 сводка при входе звала отсутствующие службы упавшими.
unit_state() {
    local load
    # Без --value: его нет до systemd 230, и там все службы выпали бы молча.
    load=$(systemctl show -p LoadState "$1" 2>/dev/null) || load=""
    load=${load#LoadState=}
    case "$load" in loaded|masked) ;; *) printf 'none'; return 0 ;; esac
    if systemctl is-active --quiet "$1" 2>/dev/null; then printf 'run'
    elif systemctl is-enabled --quiet "$1" 2>/dev/null; then printf 'down'
    else printf 'off'; fi
}
# Диск, память, нагрузка — для строки состояния.
ui_sysload() {
    local d m l
    if [ -n "${GOINST_UI_SYS:-}" ]; then read -r UD_DISK UD_MEM UD_LOAD <<<"$GOINST_UI_SYS"; return 0; fi
    d=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}') || d=""
    m=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t > 0) printf "%d", (t - a) * 100 / t}' /proc/meminfo 2>/dev/null) || m=""
    l=$(awk '{printf "%.1f", $1}' /proc/loadavg 2>/dev/null) || l=""
    case "$d" in ''|*[!0-9]*) d=0 ;; esac; case "$m" in ''|*[!0-9]*) m=0 ;; esac
    UD_DISK="$d"; UD_MEM="$m"; UD_LOAD="${l:-0.0}"
}
# «Новое»: продукт не стоит, а его main появилась с прошлого раза. Первый
# запуск запоминает всё, что есть, — иначе новым оказалось бы всё сразу.
UI_SEEN_FILE="${GOINST_SEEN_FILE:-${GOINST_DIR}/seen}"
ui_seen_init() {
    local id
    [ -e "$UI_SEEN_FILE" ] && return 0
    mkdir -p "$(dirname "$UI_SEEN_FILE")" 2>/dev/null || return 0
    for id in "${PRODUCTS[@]}"; do ver_cache_get "$id" main >/dev/null 2>&1 && printf '%s:main\n' "$id"; done > "$UI_SEEN_FILE" 2>/dev/null || true
}
ui_is_new() { [ -r "$UI_SEEN_FILE" ] && ! grep -qx "$1:main" "$UI_SEEN_FILE" 2>/dev/null; }
ui_mark_seen() { ui_is_new "$1" && printf '%s:main\n' "$1" >> "$UI_SEEN_FILE" 2>/dev/null; return 0; }

# Число по-русски: 1 день, 2 дня, 5 дней; по-английски — one/many (день по умолчанию).
ui_plural() {  # ui_plural <n> <один> <два> <пять> [one] [many] → UI_TX
    local n="$1" a=$(( $1 % 10 )) b=$(( $1 % 100 ))
    if [ "${LANG_CODE:-ru}" = en ]; then if [ "$n" = 1 ]; then UI_TX="$n ${5:-day}"; else UI_TX="$n ${6:-days}"; fi; return 0; fi
    if [ "$a" = 1 ] && [ "$b" != 11 ]; then UI_TX="$n $2"
    elif [ "$a" -ge 2 ] && [ "$a" -le 4 ] && { [ "$b" -lt 12 ] || [ "$b" -gt 14 ]; }; then UI_TX="$n $3"
    else UI_TX="$n $4"; fi
}
# Сколько дней осталось сертификату: -checkend вместо разбора даты — он
# одинаков в openssl и LibreSSL и не зависит от GNU date.
_cert_days() {  # _cert_days <файл> → UI_DAYS (−1 — истёк)
    local f="$1" lo=0 hi=400 mid
    if ! openssl x509 -checkend 0 -noout -in "$f" >/dev/null 2>&1; then UI_DAYS=-1; return 0; fi
    while [ "$lo" -lt "$hi" ]; do
        mid=$(( (lo + hi + 1) / 2 ))
        if openssl x509 -checkend $(( mid * 86400 )) -noout -in "$f" >/dev/null 2>&1; then lo=$mid; else hi=$(( mid - 1 )); fi
    done
    UI_DAYS=$lo
}
_json_str() { sed -n -E "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$1" 2>/dev/null | head -1; }
# Сертификаты по карте продуктов (design/README.md): владелец — по домену в
# config.json продукта, подсказка — проверка, которая подходит ему.
cert_scan() {
    local r="${GOINST_FS_ROOT:-}" le="${GOINST_LE_ROOT:-/etc/letsencrypt}" id d f hint seen=" " name msg short
    UI_CERTP=()
    _cert_one() {  # _cert_one <домен или IP> <файл> <подсказка> <порог дней>
        local sev=warn
        [ -r "$2" ] || return 0
        _cert_days "$2"
        [ "$UI_DAYS" -lt "$4" ] || return 0
        # Истёк — препятствие ✗. Доменному (порог 14) меньше 3 дней — тоже:
        # certbot продлевает за 30, и раз не продлил, сам уже не успеет.
        if [ "$UI_DAYS" -lt 0 ] || { [ "$4" -ge 14 ] && [ "$UI_DAYS" -lt 3 ]; }; then sev=err; fi
        if [ "$UI_DAYS" -lt 0 ]; then ut "сертификат истёк" "certificate has expired"; msg="$UI_TX"; ut "сертификат $1: истёк" "$1 cert: expired"; short="$UI_TX"
        # Меньше суток — так и сказать: «через 0 дней» читается как «уже».
        elif [ "$UI_DAYS" -eq 0 ]; then ut "сертификат истекает меньше чем через сутки" "certificate expires in less than a day"; msg="$UI_TX"
             ut "сертификат $1: меньше суток" "$1 cert: under a day left"; short="$UI_TX"
        else ui_plural "$UI_DAYS" день дня дней; local dd="$UI_TX"
             ut "сертификат истекает через $dd" "certificate expires in $dd"; msg="$UI_TX"
             ut "сертификат $1: $dd" "$1 cert: $dd left"; short="$UI_TX"; fi
        UI_CERTP+=("$1|$msg|$short|$3|$sev")
    }
    for id in govless gotelegram goamnezia godns; do
        prod_installed "$id" || continue
        f=$(prod_config_file "$id") || continue
        [ -r "$f" ] || continue
        d=$(_json_str "$f" domain)
        case "$id" in
            govless)    hint="certbot certificates" ;;
            gotelegram) [ "$(prod_installed_mode gotelegram 2>/dev/null)" = pro ] || d=""; hint="gotelegram: Сайт / SSL"; ut "gotelegram: Сайт / SSL" "gotelegram: Site / SSL"; hint="$UI_TX" ;;
            goamnezia)  grep -q '"cert"[[:space:]]*:[[:space:]]*"letsencrypt"' "$f" 2>/dev/null || d=""; ut "goamnezia: Сертификат" "goamnezia: Certificate"; hint="$UI_TX" ;;
            godns)      grep -q '"cert_owned_by_godns"[[:space:]]*:[[:space:]]*"yes"' "$f" 2>/dev/null || d=""; ut "godns: Сертификат" "godns: Certificate"; hint="$UI_TX" ;;
        esac
        [ -n "$d" ] || continue
        case "$seen" in *" $d "*) continue ;; esac
        seen+="$d "
        _cert_one "$d" "$le/live/$d/cert.pem" "$hint" 14
    done
    # Панель goVLESS pro в Lite: IP-сертификат acme.sh живёт около 6 дней,
    # поэтому тревога — только когда осталось меньше двух.
    if prod_installed govless; then
        for f in "$r"/root/cert/ip/*.crt; do
            [ -r "$f" ] || continue
            d=$(basename "$f" .crt); _cert_one "$d" "$f" "acme.sh --list" 2
        done
    fi
    return 0
}

# ui_model_load — модель экрана из системы: продукты, версии, готовность,
# порты, службы, сертификаты, ключ.
ui_model_load() {
    local i id v inst free st rv refs m rest u us ok k c
    # Один скан портов и контейнеров на всю пересборку: без этого каждая
    # проверка каждого продукта снова звала ss и docker ps, и на сервере с
    # Docker меню замирало на секунды.
    local own_cache=""
    if [ -z "${GOINST_SCAN_CACHE:-}" ]; then scan_cache_begin; own_cache=1; fi
    UD_HOST=$(hostname -s 2>/dev/null) || UD_HOST=""; [ -n "$UD_HOST" ] || UD_HOST=server
    UD_OS="${OS_PRETTY:-}"; UD_VER="$GOINST_VERSION"
    # Своя версия — из той же лучшей ветки, что у нумерованного меню (main,
    # dev и запомненная): обновления между ветками обязаны проходить и в
    # «Аркаде» (решение владельца 04.11, REVIEW-8 №3). Ветку экран называет.
    UD_VERNEW=""; UD_SELFREF=""
    if v=$(self_best 2>/dev/null) && ver_newer "$GOINST_VERSION" "${v#* }"; then UD_VERNEW="${v#* }"; UD_SELFREF="${v%% *}"; fi
    UD_SVED="${UI_SVED:-$(date +%H:%M)}"
    ui_sysload
    scan_listeners; scan_docker
    UD_NAME=(); UD_CMD=(); UD_DESC=(); UD_INST=(); UD_SRV=(); UD_MAIN=(); UD_DEV=(); UD_BRANCH=(); UD_UPD=(); UD_NEW=()
    UD_DEVREF=(); UD_UPDV=()
    UD_ST=(); UD_STTXT=(); UD_MODES=(); UD_DEFMODE=(); UD_SVC=(); UD_SVCOK=(); UD_HELD=(); UD_HELDP=(); UD_NEED=(); UD_VBAD=(); UD_VNOTES=(); UD_VWHY=()
    UD_NEWS=(); UD_PROB=(); UD_NINST=0
    ui_seen_init
    for ((i = 0; i < ${#PRODUCTS[@]}; i++)); do
        id="${PRODUCTS[$i]}"
        UD_NAME[i]=$(prod_name "$id"); UD_CMD[i]=$(prod_cmd "$id"); UD_DESC[i]=$(prod_desc "$id")
        inst=0; prod_installed "$id" && inst=1
        free=""; [ "$inst" = 1 ] && free=$(prod_free_edition "$id" 2>/dev/null)
        v=$(prod_version "$id" 2>/dev/null) || v=""
        UD_INST[i]=$inst
        read -r -a refs <<<"$(prod_refs "$id")"
        UD_MAIN[i]=$(ver_cache_get "$id" "${refs[0]:-main}" 2>/dev/null) || UD_MAIN[i]=""
        UD_DEV[i]=""; UD_DEVREF[i]="${refs[1]:-}"; UD_UPDV[i]=""
        if [ -n "${refs[1]:-}" ]; then UD_DEV[i]=$(ver_cache_get "$id" "${refs[1]}" 2>/dev/null) || UD_DEV[i]="?"; [ -n "${UD_DEV[i]}" ] || UD_DEV[i]="?"; fi
        UD_BRANCH[i]=$(prod_installed_ref "$id" 2>/dev/null) || UD_BRANCH[i]=""
        [ -n "${UD_BRANCH[i]}" ] || UD_BRANCH[i]="${refs[0]:-main}"
        UD_UPD[i]=0; UD_NEW[i]=0; UD_STTXT[i]=""
        if [ "$inst" = 1 ]; then
            UD_NINST=$(( UD_NINST + 1 ))
            if [ -n "$free" ]; then
                UD_ST[i]=free; ut "бесплатный $free" "free $free"; UD_STTXT[i]="$UI_TX"
                if prod_free_shows_version "$id" && [ -n "$v" ]; then UD_SRV[i]="$v"; else UD_SRV[i]="—"; fi
            else
                UD_ST[i]=installed; UD_SRV[i]="${v:-?}"
                rv=$(ver_cache_get "$id" "${UD_BRANCH[i]}" 2>/dev/null) || rv=""
                if [ -n "$rv" ] && [ -n "$v" ] && ver_newer "$v" "$rv"; then
                    UD_UPD[i]=1; UD_UPDV[i]="$rv"
                    ut "обновление в ${UD_BRANCH[i]}" "update in ${UD_BRANCH[i]}"
                    UD_NEWS+=("↑|update|${UD_NAME[i]}|$v → $rv|$UI_TX")
                fi
            fi
        else
            UD_SRV[i]="—"
            st=$(prod_readiness "$id" 2>/dev/null) || st="g:"
            rest="${st#*:}"
            case "$st" in
                g:*) UD_ST[i]=ready ;;
                y:*) ut "готов, есть замечания" "ready, with remarks"; if [ "$rest" = "$UI_TX" ]; then UD_ST[i]=notes; else UD_ST[i]=lite; UD_STTXT[i]="$rest"; fi ;;
                *)   UD_ST[i]=block; UD_STTXT[i]="$rest" ;;
            esac
            if [ -n "${UD_MAIN[i]}" ] && ui_is_new "$id"; then
                UD_NEW[i]=1
                ut "новый продукт серии, main" "new in the series, main"
                UD_NEWS+=("✚|new|${UD_NAME[i]}|${UD_MAIN[i]}|$UI_TX")
            fi
        fi
        m=$(prod_mode_choices "$id")
        [ "$inst" = 1 ] && m="${m//lazy /}"
        UD_MODES[i]="$m"
        if [ "$inst" = 1 ] && v=$(prod_installed_mode "$id" 2>/dev/null); then UD_DEFMODE[i]="$v"; else UD_DEFMODE[i]=$(prod_mode_default "$id"); fi
        # Службы и порты.
        UD_SVC[i]=$(prod_units "$id"); UD_SVCOK[i]=""
        if [ "$inst" = 1 ] && command -v systemctl >/dev/null 2>&1; then
            UD_SVC[i]=""
            for u in $(prod_units "$id"); do
                us=$(unit_state "$u")
                case "$us" in
                    none) continue ;;
                    run)  UD_SVCOK[i]+=" $u:1" ;;
                    off)  UD_SVCOK[i]+=" $u:2" ;;
                    *)    UD_SVCOK[i]+=" $u:0"; ut "$u не работает" "$u is not running"
                          UD_PROB+=("${UD_NAME[i]}|$UI_TX|${UD_NAME[i]}: $UI_TX|journalctl -u $u") ;;
                esac
                UD_SVC[i]+="${UD_SVC[i]:+ }$u"
            done
        fi
        UD_HELD[i]=""; UD_HELDP[i]=""
        if [ "$inst" = 1 ]; then
            local l p a po pr pi own seen=" "
            while IFS='|' read -r p a po pr pi; do
                [ -n "$po" ] || continue
                own=$(holder_product "$pr" "$pi")
                [ "$own" = "$id" ] || continue
                case "$seen" in *" $po/$p "*) continue ;; esac
                seen+="$po/$p "; UD_HELD[i]+="${UD_HELD[i]:+ }$po/$p"; UD_HELDP[i]+="${UD_HELDP[i]:+ }$po/$p=$pr"
            done < <(printf '%s\n' "$LISTENERS" | sort -t'|' -k3,3n)
        else
            UD_NEED[i]=$(prod_ports "$id" "${UD_DEFMODE[i]:-pro}" | awk -F'|' '{printf "%s%s/%s", (NR>1?" ":""), $2, $1}')
            preflight "$id" "${UD_DEFMODE[i]:-pro}" >/dev/null 2>&1
            UD_VBAD[i]="$PF_MUST"; UD_VNOTES[i]="$PF_SOFT"
            # Первое замечание или препятствие словами — для карточки: одно
            # число «замечаний: 1» не говорит, что именно не так.
            UD_VWHY[i]=""
            for m in ${PF_MSGS[@]+"${PF_MSGS[@]}"}; do case "$m" in e\|*|w\|*) UD_VWHY[i]="${m#?|}"; break ;; esac; done
            # Мешает только ОС, а обновление Ubuntu это лечит — сказать, где оно.
            if [ "$PF_MUST" -gt 0 ] && [ "$PF_MUST" -eq "$PF_OSMUST" ] && osup_hint_ok "$id"; then
                ut "обновить Ubuntu: пункт o" "upgrade Ubuntu: item o"; UD_VWHY[i]+=" ${UI_TX}"
            fi
        fi
    done
    # Сам goInstaller.
    if [ -n "$UD_VERNEW" ]; then ut "новая версия установщика" "new installer version"; UD_NEWS+=("↑|update|goInstaller|$GOINST_VERSION → $UD_VERNEW|$UI_TX"); fi
    cert_scan
    # Окружения ботов от прежнего python — замечание под меню и в сводке при входе.
    comp_bots_load; comp_bot_probs
    # Обновление Ubuntu — первыми строками (UD_OSUPN штук): сводка при входе
    # берёт их не из файла, а из состояния, вживую.
    osup_model; osup_probs; UD_OSUPN=${#OSUP_PROBS[@]}
    # Защита от сканеров — вживую (nft), сломалась — чинится как тактом
    # таймера; не вышло — ✗ под меню, сразу за Ubuntu (в 46 колонок нижние
    # строки обрезаются). В файл сводки не пишется: при входе её состояние
    # читается из своих файлов (summary_print).
    shield_state --live; shield_probs
    # Числа статистики защиты — только для открытой «Аркады».
    if [ "${UI_COMPS:-0}" = 1 ]; then ui_sh_model; fi
    UD_PROB=(${OSUP_PROBS[@]+"${OSUP_PROBS[@]}"} ${SHIELD_PROBS[@]+"${SHIELD_PROBS[@]}"} "${UI_CERTP[@]}" ${UD_PROB[@]+"${UD_PROB[@]}"} ${COMP_BOTP[@]+"${COMP_BOTP[@]}"})
    # Компоненты apt — только для открытой «Аркады» (UI_COMPS): таймеру сводки
    # при входе они не нужны.
    UD_COMPUP=0
    if [ "${UI_COMPS:-0}" = 1 ]; then comp_apt_load >/dev/null 2>&1; UD_COMPUP="${COMP_NUP:-0}"; fi
    # Ключ.
    UD_KEYDENIED=""; UD_KEYOK=6; UD_KEYTOK=muted
    case "${TOKEN_STATUS:-}" in
        ok)      ut "сохранён, проверен в ${UI_KEYAT:-$UD_SVED}" "saved, checked at ${UI_KEYAT:-$UD_SVED}"; UD_KEYNOTE="$UI_TX" ;;
        denied)  UD_KEYDENIED="${TOKEN_DENIED% }"; c=0; for k in $TOKEN_DENIED; do [ "$k" = pro ] && c=$(( c + 1 )); done
                 UD_KEYOK=$(( 6 - c )); ut "не открывает ${UD_KEYDENIED}" "does not open ${UD_KEYDENIED}"; UD_KEYNOTE="$UI_TX"; UD_KEYTOK=warn ;;
        limited) ut "лимит GitHub до $(gh_reset_text)" "GitHub limit until $(gh_reset_text)"; UD_KEYNOTE="$UI_TX"; UD_KEYTOK=warn ;;
        nonet)   ut "GitHub недоступен" "GitHub is unreachable"; UD_KEYNOTE="$UI_TX"; UD_KEYTOK=warn ;;
        *)       if [ -n "${TOKEN:-}" ]; then ut "сохранён" "saved"; UD_KEYNOTE="$UI_TX"; else ut "ключа нет" "no key"; UD_KEYNOTE="$UI_TX"; UD_KEYTOK=warn; fi ;;
    esac
    if [ "${LANG_CODE:-ru}" = en ]; then UD_LANGNOTE="English"; else UD_LANGNOTE="русский"; fi
    [ -n "$own_cache" ] && scan_cache_end
    return 0
}

# Строки проверки портов для экрана: preflight считает, экран показывает.
ui_pf_load() {  # ui_pf_load <id> <режим>
    local r port st what who m t
    with_scan_cache preflight "$1" "${2:-pro}" >/dev/null 2>&1
    UI_PFR_PORT=(); UI_PFR_ST=(); UI_PFR_D=(); UI_PFR_H=()
    # Свободные порты функций, которые включают потом (prod_ports_opt), —
    # одной строкой: у goKaskad pro 3 их полтора десятка, и экран без
    # прокрутки терял пункт «Продолжить». Занятые — каждый своей строкой.
    local opt nopt=0
    opt=" $(prod_ports_opt "$1" | awk -F'|' '{printf "%s/%s ", $2, $1}')"
    for r in ${PF_ROWS[@]+"${PF_ROWS[@]}"}; do
        IFS='|' read -r port st what who <<<"$r"
        if [ "$st" = ok ] && [[ "$opt" == *" $port "* ]]; then nopt=$(( nopt + 1 )); continue; fi
        UI_PFR_PORT+=("$port"); UI_PFR_ST+=("$st"); UI_PFR_D+=("$what"); UI_PFR_H+=("$who")
    done
    if [ "$nopt" -gt 0 ]; then
        ut "порты функций продукта свободны" "the product's feature ports are free"
        UI_PFR_PORT+=("+${nopt}"); UI_PFR_ST+=(ok); UI_PFR_D+=("$UI_TX"); UI_PFR_H+=("")
    fi
    UI_PFU_G=(); UI_PFU_T=(); UI_PFU_TXT=()
    for m in ${PF_MSGS[@]+"${PF_MSGS[@]}"}; do
        t="${m%%|*}"; m="${m#*|}"
        case "$t" in e) UI_PFU_G+=('✗'); UI_PFU_T+=(err) ;; w) UI_PFU_G+=('!'); UI_PFU_T+=(warn) ;; o) UI_PFU_G+=('✓'); UI_PFU_T+=(ok) ;; *) UI_PFU_G+=('·'); UI_PFU_T+=(muted) ;; esac
        UI_PFU_TXT+=("$m")
    done
    UI_PF_BAD="$PF_MUST"; UI_PF_NOTES="$PF_SOFT"
}
# Итог проверки для каждого режима — тег в вопросе о режиме.
ui_modes_load() {  # ui_modes_load <индекс продукта>
    local m id="${PRODUCTS[$1]}"
    declare -gA UI_MVBAD=() UI_MVNOTES=()
    _ui_modes_scan() {
        for m in ${UD_MODES[$1]}; do
            preflight "$id" "$m" >/dev/null 2>&1
            UI_MVBAD[$m]="$PF_MUST"; UI_MVNOTES[$m]="$PF_SOFT"
        done
    }
    with_scan_cache _ui_modes_scan "$1"
}
# Карта портов: группы по владельцу — продукты серии, потом система и прочие.
ui_ports_load() {
    local p a po pr pi own id what key i
    declare -A rows=() seenp=()
    scan_listeners; scan_docker
    while IFS='|' read -r p a po pr pi; do
        [ -n "$po" ] || continue
        [ -z "${seenp[$po/$p]:-}" ] || continue
        seenp[$po/$p]=1
        own=$(holder_product "$pr" "$pi")
        what="$pr"
        for id in "${PRODUCTS[@]}"; do
            [ "$own" = "$id" ] || continue
            what=$({ for m in $(prod_modes "$id") pro; do prod_ports "$id" "$m"; done; prod_ports_opt "$id"; } | awk -F'|' -v P="$po" -v Q="$p" '$1==Q && $2==P {print $4; exit}')
            [ -n "$what" ] || what="$pr"
        done
        case "$own" in govless|gotelegram|godns|gokaskad|gowarp|goamnezia) key="$own" ;; system) key="@system" ;; *) key="@other" ;; esac
        rows[$key]+="${rows[$key]:+;}$po/$p|$pr|$what"
    done < <(printf '%s\n' "$LISTENERS" | sort -t'|' -k3,3n -k1,1)
    UI_PG_NAME=(); UI_PG_ROWS=()
    for id in "${PRODUCTS[@]}"; do [ -n "${rows[$id]:-}" ] && { UI_PG_NAME+=("$(prod_name "$id")"); UI_PG_ROWS+=("${rows[$id]}"); }; done
    if [ -n "${rows[@system]:-}" ]; then ut "система" "system"; UI_PG_NAME+=("$UI_TX"); UI_PG_ROWS+=("${rows[@system]}"); fi
    if [ -n "${rows[@other]:-}" ]; then ut "прочие" "others"; UI_PG_NAME+=("$UI_TX"); UI_PG_ROWS+=("${rows[@other]}"); fi
    if [ "${#UI_PG_NAME[@]}" -eq 0 ]; then ut "слушателей нет" "no listeners"; UI_PG_NAME=("$UI_TX"); UI_PG_ROWS=(""); fi
    return 0
}

# ── опрос GitHub в фоне с ходом для заставки ───────────────────────────
# Восемь строк: goInstaller, ключ, шесть продуктов. Каждая задача по
# окончании кладёт файл в UI_POLLDIR; экран читает их на каждом такте.
ui_poll_start() {
    local id cfg
    # Без сети (GOINST_NO_NET) не опрашиваем и по таймеру меню: с подставным
    # ключом опрос получал отказ и затирал кеш версий пустыми строками.
    [ -z "${GOINST_NO_NET:-}" ] || return 1
    # Без ключа опрос не делается вовсе (решение владельца 6): он шёл бы с
    # пустым заголовком, сдвигал «сведения от» и писал промахи в кеш.
    [ -n "${TOKEN:-}" ] || return 1
    UI_POLLDIR=$(mktemp -d "${TMPDIR:-/tmp}/goinst-poll.XXXXXX") || return 1
    UI_POLLT0=$SECONDS
    (
        cfg=$(mktemp "${TMPDIR:-/tmp}/goinst-pollc.XXXXXX") || exit 0
        chmod 600 "$cfg"
        { echo 'silent'; echo 'location'; echo 'fail'; gh_cfg_net
          printf 'header = "Authorization: token %s"\n' "$TOKEN"; } > "$cfg"
        # Повторы и «сети нет» — общие на весь опрос: заставка их показывает.
        GH_RETRY_LOG="$UI_POLLDIR/retries"; GH_DOWN_FILE="$UI_POLLDIR/down"; GH_SAY=""
        ( token_check >/dev/null 2>&1; printf '%s|%s|%s\n' "${TOKEN_STATUS:-}" "${TOKEN_DENIED:-}" "${TOKEN_NETRC:-}" > "$UI_POLLDIR/key" ) &
        ( rm -f "$(_ver_cache_file "$SELF_ID" main)"; self_fetch_versions >/dev/null 2>&1; : > "$UI_POLLDIR/self" ) &
        for id in "${PRODUCTS[@]}"; do
            (
                refs_fetch_one "$id" "$cfg" >/dev/null 2>&1
                for ref in $(prod_refs_probe "$id"); do _ver_fetch_one "$id" "$ref" "$cfg" >/dev/null 2>&1; done
                if ver_cache_get "$id" main >/dev/null 2>&1 && [ -n "$(ver_cache_get "$id" main)" ]; then : > "$UI_POLLDIR/p_$id"; else echo fail > "$UI_POLLDIR/p_$id"; fi
            ) &
        done
        wait
        rm -f "$cfg"
        : > "$UI_POLLDIR/all"
    ) </dev/null >/dev/null 2>&1 &
    UI_POLLPID=$!
    return 0
}
# Состояние опроса → строки заставки UI_PI_* и счётчик UI_POLL.
ui_poll_state() {
    local i id n=0 st res tok k den
    UI_PI_NOTE=""
    if [ -s "$UI_POLLDIR/retries" ]; then
        local lrc ltry ltot
        read -r lrc ltry ltot < <(tail -n 1 "$UI_POLLDIR/retries")
        UI_PI_NOTE="$(bi "GitHub отвечает с трудом, повтор ${ltry} из ${ltot}" "GitHub answers with difficulty, retry ${ltry} of ${ltot}"): $(gh_net_reason "$lrc")"
    fi
    UI_PI_NAME=("goInstaller"); ut "ключ доступа" "access key"; UI_PI_NAME+=("$UI_TX")
    for id in "${PRODUCTS[@]}"; do UI_PI_NAME+=("$(prod_name "$id")"); done
    UI_PI_ST=(); UI_PI_RES=(); UI_PI_TOK=()
    if [ -e "$UI_POLLDIR/self" ]; then
        local sv; sv=$(ver_cache_get "$SELF_ID" main 2>/dev/null) || sv=""
        UI_PI_ST+=(done); UI_PI_RES+=("${sv:-$GOINST_VERSION}"); if [ -n "$sv" ] && ver_newer "$GOINST_VERSION" "$sv"; then UI_PI_TOK+=(update); else UI_PI_TOK+=(text); fi
    else UI_PI_ST+=(run); UI_PI_RES+=(""); UI_PI_TOK+=(text); fi
    if [ -e "$UI_POLLDIR/key" ]; then
        IFS='|' read -r st den _ < "$UI_POLLDIR/key"
        k=0; for id in $den; do [ "$id" = pro ] && k=$(( k + 1 )); done
        case "$st" in
            ok|denied) ut "открывает $(( 6 - k )) из 6" "opens $(( 6 - k )) of 6"; UI_PI_ST+=(done); UI_PI_RES+=("$UI_TX"); if [ "$k" -gt 0 ]; then UI_PI_TOK+=(warn); else UI_PI_TOK+=(text); fi ;;
            bad) ut "401: ключ не принят" "401: key rejected"; UI_PI_ST+=(fail); UI_PI_RES+=("$UI_TX"); UI_PI_TOK+=(err) ;;
            *) UI_PI_ST+=(fail); UI_PI_RES+=(""); UI_PI_TOK+=(err) ;;
        esac
    else UI_PI_ST+=(run); UI_PI_RES+=(""); UI_PI_TOK+=(text); fi
    for ((i = 0; i < ${#PRODUCTS[@]}; i++)); do
        id="${PRODUCTS[$i]}"
        if [ -e "$UI_POLLDIR/p_$id" ]; then
            if [ -s "$UI_POLLDIR/p_$id" ]; then UI_PI_ST+=(fail); UI_PI_RES+=(""); UI_PI_TOK+=(err); continue; fi
            local refs mv dv; read -r -a refs <<<"$(prod_refs "$id")"
            mv=$(ver_cache_get "$id" "${refs[0]:-main}" 2>/dev/null) || mv=""; res="${refs[0]:-main} ${mv:-—}"
            if [ -n "${refs[1]:-}" ]; then dv=$(ver_cache_get "$id" "${refs[1]}" 2>/dev/null) || dv=""; res+=" · ${refs[1]} ${dv:-—}"; fi
            tok=text
            if prod_installed "$id"; then local lv; lv=$(prod_version "$id" 2>/dev/null) || lv=""; [ -n "$lv" ] && [ -n "$mv" ] && ver_newer "$lv" "$mv" && tok=update
            elif ui_is_new "$id"; then tok=new; fi
            UI_PI_ST+=(done); UI_PI_RES+=("$res"); UI_PI_TOK+=("$tok")
        else UI_PI_ST+=(run); UI_PI_RES+=(""); UI_PI_TOK+=(text); fi
    done
    for st in "${UI_PI_ST[@]}"; do case "$st" in done|fail) n=$(( n + 1 )) ;; esac; done
    UI_POLL="$n"
    [ -e "$UI_POLLDIR/all" ]
}
# Опрос кончился: отметки, ключ, сведения, ошибка — и прибрать за собой.
ui_poll_finish() {
    local st den
    [ -n "${UI_POLLDIR:-}" ] || return 0
    UI_NETRC=""
    if [ -r "$UI_POLLDIR/key" ]; then IFS='|' read -r st den UI_NETRC < "$UI_POLLDIR/key"; TOKEN_STATUS="$st"; TOKEN_DENIED="$den"; UI_KEYAT=$(date +%H:%M); fi
    # Ключ из окружения сохраняем, когда он подтвердился: иначе установка
    # одной командой работала бы ровно один раз.
    if [ "${TOKEN_FROM:-}" = env ] && [ "${TOKEN_STATUS:-}" = ok ] && [ "$TOKEN" != "$(head -1 "$TOKEN_FILE" 2>/dev/null)" ]; then token_save "$TOKEN" >/dev/null 2>&1 || true; fi
    UI_POLLERR=""
    if gh_limited >/dev/null; then UI_POLLERR=rate; UI_RESET=$(gh_reset_text)
    elif [ "${TOKEN_STATUS:-}" = nonet ]; then UI_POLLERR=github
    else UI_SVED=$(date +%H:%M); fi
    UI_POLLOK=0; local s; for s in ${UI_PI_ST[@]+"${UI_PI_ST[@]}"}; do [ "$s" = done ] && UI_POLLOK=$(( UI_POLLOK + 1 )); done
    VER_NET_TRIED="yes"; _ver_mark_ok "${PRODUCTS[@]}"
    rm -rf "$UI_POLLDIR"; UI_POLLDIR=""; UI_POLL=""; UI_POLLPID=""
}

# ── клавиши ────────────────────────────────────────────────────────────
# ui_read_key [тайм-аут] → UI_KEY: up down enter esc back tick eof paste
# или сам символ. Русская раскладка: з к д г й — это p r l u q.
# Вставка из буфера приходит пачкой за миллисекунды: её гасим целиком,
# иначе вставленная команда нажимала бы пункты меню буква за буквой.
ui_read_key() {
    local k rest="" rc t="${1:-}" more
    UI_KEY=""; UI_ARROW=""
    if [ -n "$t" ]; then IFS= read -rsn1 -t "$t" k; rc=$?; else IFS= read -rsn1 k; rc=$?; fi
    if [ "$rc" -ne 0 ]; then if [ "$rc" -gt 128 ]; then UI_KEY=tick; else UI_KEY=eof; fi; return 0; fi
    case "$k" in
        # \r — тоже Enter: так приходит Enter не из терминала (ввод каналом,
        # «отправить текст» в SSH-клиенте). Из терминала bash на время
        # read -n сам включает icrnl — проверено на сервере с stty -icrnl.
        # Несколько Enter пачкой — одно нажатие.
        ''|$'\r')
            if [ "${UI_INPUT:-0}" = 0 ]; then
                while IFS= read -rsn1 -t 0.01 more; do
                    case "$more" in ''|$'\r') ;; *) while IFS= read -rsn1 -t 0.01 more; do :; done; UI_KEY=paste; return 0 ;; esac
                done
            fi
            UI_KEY=enter; return 0 ;;
        $'\177'|$'\b') UI_KEY=back; return 0 ;;
        $'\033')
            IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=""
            # «\033O…» — те же стрелки в режиме курсора приложения: в нём
            # терминал остаётся, если его не вернула прошлая программа.
            case "$rest" in
                # ←→ — по-прежнему Enter и Esc; какая стрелка — в UI_ARROW
                # (на графике статистики они листают, ui_sh_arrow).
                '[A'|OA) UI_KEY=up ;; '[B'|OB) UI_KEY=down ;; '[C'|OC) UI_KEY=enter; UI_ARROW=right ;; '[D'|OD) UI_KEY=esc; UI_ARROW=left ;;
                '[H'|OH) UI_KEY=home ;; '[F'|OF) UI_KEY=end ;;
                # F-клавиши: «\033OQ» (xterm, iTerm, Termius), «\033[12~»
                # (rxvt, PuTTY), «\033[[B» (консоль Linux). F1, F10, F11 не
                # берём: их перехватывают система и терминалы.
                OQ) UI_KEY=f2 ;; OR) UI_KEY=f3 ;; OS) UI_KEY=f4 ;;
                '[1'|'[['|'[4'|'[5'|'[6'|'[7'|'[8')
                    local tail="" ch
                    while IFS= read -rsn1 -t 0.05 ch; do tail+="$ch"; case "$ch" in '~'|[A-E]) break ;; esac; done
                    case "$rest$tail" in
                        '[12~'|'[[B'|'[1;1Q'|'[1Q') UI_KEY=f2 ;;
                        '[13~'|'[[C'|'[1R') UI_KEY=f3 ;;
                        '[14~'|'[[D'|'[1S') UI_KEY=f4 ;;
                        '[15~'|'[[E') UI_KEY=f5 ;;
                        '[1~'|'[7~') UI_KEY=home ;; '[4~'|'[8~') UI_KEY=end ;;
                        '[5~') UI_KEY=pgup ;; '[6~') UI_KEY=pgdn ;;
                        *) UI_KEY=other ;;
                    esac ;;
                '') UI_KEY=esc ;;
                *) while IFS= read -rsn1 -t 0.01 more; do :; done; UI_KEY=other ;;
            esac
            return 0 ;;
    esac
    if [ "${UI_INPUT:-0}" = 0 ] && IFS= read -rsn1 -t 0.01 more; then
        # Вслед пришло ещё. «Цифра и сразу Enter» — привычка прежнего меню, а
        # ту же клавишу жмут по нескольку раз, когда экран не отозвался сразу:
        # это одно нажатие. До 1.0.2 такая пачка шла во «вставку» и молча
        # пропадала — меню выглядело зависшим. Всё прочее — вставка из буфера,
        # её не исполняем: вставленная команда не должна жать пункты меню.
        local burst="$more"
        while IFS= read -rsn1 -t 0.01 more; do burst+="$more"; done
        burst="${burst//$'\r'/}"; burst="${burst//"$k"/}"
        if [ -n "$burst" ]; then UI_KEY=paste; return 0; fi
    fi
    [ "${UI_INPUT:-0}" = 0 ] && case "$k" in з|З) k=p ;; к|К) k=r ;; д|Д) k=l ;; г|Г) k=u ;; й|Й) k=q ;; с|С) k=c ;; ф|Ф) k=a ;; щ|Щ) k=o ;; ы|Ы) k=s ;; esac
    UI_KEY="$k"
}

# Сейчас в миллисекундах → UI_NOW. EPOCHREALTIME пишет дробь через
# десятичный знак локали (в ru_RU — запятая), поэтому убираем оба.
_ui_now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then t="${t//[!0-9]/}"; UI_NOW=$(( 10#${t:0:${#t}-3} )); else UI_NOW=$(( SECONDS * 1000 )); fi
}
# Выбросить набранное вслепую, пока экран был отдан продукту.
ui_flush_input() { local _k; while IFS= read -rsn1 -t 0.01 _k; do :; done; return 0; }

# ── навигация ──────────────────────────────────────────────────────────
# Экран — UI_SCR и его параметры; назад — стек. Рисует ui_draw, действия —
# ui_act. Установщик продукта идёт в обычном терминале: экран отдаётся ему
# целиком, как было и до «Аркады».
UI_STACK=()
ui_push() { UI_STACK+=("$UI_SCR|$UI_CUR|${UI_WP:-}|${UI_PMODE:-}|${UI_PBRANCH:-}|${UI_WIZ:-0}|${UI_ONLY:-0}"); }
ui_go() { ui_push; UI_SCR="$1"; UI_CUR="${2:-0}"; }
ui_back() {
    local n="${#UI_STACK[@]}" e
    if [ "$n" -eq 0 ]; then UI_SCR=quit; return 0; fi
    e="${UI_STACK[$(( n - 1 ))]}"; unset "UI_STACK[$(( n - 1 ))]"; UI_STACK=(${UI_STACK[@]+"${UI_STACK[@]}"})
    IFS='|' read -r UI_SCR UI_CUR UI_WP UI_PMODE UI_PBRANCH UI_WIZ UI_ONLY <<<"$e"
}
ui_root() { UI_STACK=(); UI_SCR="${1:-menu}"; UI_CUR=0; }
ui_back_to() {  # ui_back_to <экран> — назад до него, нет в стеке — в меню
    local i n="${#UI_STACK[@]}" e s
    for ((i = n - 1; i >= 0; i--)); do
        e="${UI_STACK[$i]}"; s="${e%%|*}"
        if [ "$s" = "$1" ]; then
            UI_STACK=("${UI_STACK[@]:0:$i}")
            IFS='|' read -r UI_SCR UI_CUR UI_WP UI_PMODE UI_PBRANCH UI_WIZ UI_ONLY <<<"$e"; return 0
        fi
    done
    ui_root menu
}

ui_enter_screen() { printf '\033[?1049h\033[?25l' >/dev/tty 2>/dev/null || printf '\033[?1049h\033[?25l'; UI_ALT=1; }
ui_leave_screen() { printf '\033[0m\033[?25h\033[?1049l' >/dev/tty 2>/dev/null || printf '\033[0m\033[?25h\033[?1049l'; UI_ALT=0; }

# Нарисовать текущий экран.
ui_draw() {
    local p="${UI_WP:-0}"
    UI_SPIN="${UI_SPINS:0:1}"
    case "$UI_C" in 40) UI_SCR_DRAWN=small; ui_scr_small; ui_compose; ui_emit
                        [ -n "${GOINST_UI_TRACE:-}" ] && printf 'small\n' >> "${GOINST_UI_TRACE}.draw"
                        return 0 ;; esac
    UI_SCR_DRAWN="$UI_SCR"
    case "$UI_SCR" in
        menu)    [ -n "${UI_POLLDIR:-}" ] && ui_poll_state; ui_scr_menu "$UI_CUR" ;;
        splash)  ui_poll_state; ui_scr_splash ;;
        product) ui_scr_product "$p" "$UI_CUR" ;;
        mode)    ui_scr_mode "$p" "$UI_CUR" "${UI_ONLY:-0}" ;;
        check)   ui_scr_check "$p" "$UI_CUR" "${UI_WIZ:-0}" ;;
        branch)  ui_scr_branch "$p" "$UI_CUR" ;;
        confirm) ui_scr_confirm "$p" "$UI_CUR" ;;
        result)  ui_scr_result "$p" "$UI_CUR" ;;
        ports)   ui_scr_ports "$UI_CUR" ;;
        key)     ui_scr_key "$UI_CUR" ;;
        keyinput) ui_scr_keyinput "${#UI_KEYBUF}" "${UI_KEYST:-}" ;;
        nokey)   ui_scr_nokey "$UI_CUR" ;;
        lang)    ui_scr_lang "$UI_CUR" ;;
        err)     ui_scr_err "${UI_POLLERR:-github}" "$UI_CUR" ;;
        selfupd) ui_scr_selfupd "$UI_CUR" ;;
        uninstall) ui_scr_uninstall "$UI_CUR" ;;
        sumask)  ui_scr_sumask "$UI_CUR" ;;
        comps)   ui_scr_comps "$UI_CUR" ;;
        shield)  ui_scr_shield "$UI_CUR" ;;
        shstats) ui_scr_shstats ;;
        shtop)   ui_scr_shtop ;;
        shset)   ui_scr_shset ;;
        compconfirm) ui_scr_compconfirm "$UI_CUR" ;;
        osupg)   ui_scr_osupg "$UI_CUR" ;;
    esac
    # Короткая подсказка поверх строки сведений: пропущенная вставка и т. п.
    [ -n "${UI_NOTE:-}" ] && UI_INFO="warn${UI_US}  ${UI_NOTE}${UI_RS}"
    ui_compose; ui_emit
    [ -n "${GOINST_UI_TRACE:-}" ] && printf '%s\n' "$UI_SCR_DRAWN" >> "${GOINST_UI_TRACE}.draw"
    return 0
}
# Удалить goInstaller: что уйдёт, что останется, выбор про ключ.
ui_scr_uninstall() {
    local l
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "Удалить goInstaller" "Remove goInstaller"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" ""; ui_body ""
    ut "Уйдут команды goinstall и go-installer, каталог /opt/go-installer и таймер сводки при входе. Продукты, их команды и настройки останутся, размер пакета сетевой карты — тоже." "The goinstall and go-installer commands, /opt/go-installer and the login summary timer go away. The products, their commands and settings stay, and so does the network card packet size."
    ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  ${l}${UI_RS}"; done
    ui_body ""
    UI_TX=""
    if [ "${SHS_ST:-none}" != none ]; then
        ut "Защита от сканеров снимется вместе с ним: правила nft, таймер, списки, статистика." "Scanner protection goes with it: the nft rules, the timer, the lists, the statistics."
    elif _shield_has_stats; then
        ut "Статистика защиты от сканеров удалится вместе с ним." "Scanner protection statistics go with it."
    fi
    if [ -n "$UI_TX" ]; then
        ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "warn${UI_US}  ${l}${UI_RS}"; done
        ui_body ""
    fi
    if [ -f "$TOKEN_FILE" ]; then
        ut "Ключ клуба goKaskad pro берёт как запасной, а goInstaller подхватит при новой установке." "goKaskad pro uses the club key as a fallback, and goInstaller picks it up when installed again."
        ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  ${l}${UI_RS}"; done
        ui_body ""
    fi
    ui_items_clear
    ut "Удалить вместе с ключом" "Remove, key included"; ui_item 1 "$UI_TX" uninstall_drop
    if [ -f "$TOKEN_FILE" ]; then ut "Удалить, ключ оставить" "Remove, keep the key"; ui_item 2 "$UI_TX" uninstall_keep; fi
    ut "Назад" "Back"; ui_item 0 "$UI_TX" back
    ui_choicerows "$UI_CUR"
    local a; ut "выбрать" "choose"; a="$UI_TX"; ut "назад" "back"; ui_keys_fit "1–2|$a|" "0|$UI_TX|"
}
# Обновить goInstaller: подтверждение цифрой.
ui_scr_selfupd() {
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "Обновить goInstaller" "Update goInstaller"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" ""; ui_body ""
    local r="${UD_SELFREF:-main}" t
    ut " · ветка ${r}" " · branch ${r}"
    t="title${UI_US}  goInstaller ${UI_RS}text${UI_US}${UD_VER}${UI_RS}muted${UI_US} → ${UI_RS}update${UI_US}${UD_VERNEW:-?}${UI_RS}"
    # Длинное имя ветки в 46 не встаёт за номером — тогда строкой ниже.
    if [ $(( $(str_len "  goInstaller ${UD_VER} → ${UD_VERNEW:-?}${UI_TX}") )) -lt "$UI_C" ]; then
        ui_body "${t}muted${UI_US}${UI_TX}${UI_RS}"
    else
        ui_body "$t"; ui_fit "muted${UI_US}  ${UI_TX# · }${UI_RS}" $(( UI_C - 1 )); ui_body "$UI_FIT"
    fi
    ui_body ""
    ut "Запустить обновление?" "Run the update?"; ui_body "title${UI_US}  ${UI_TX}${UI_RS}"
    ut "Да" "Yes"; ui_body "muted${UI_US}  Enter — 1, ${UI_TX}${UI_RS}"; ui_body ""
    ui_items_clear; ut "Да" "Yes"; ui_item 1 "$UI_TX" selfyes; ut "Нет" "No"; ui_item 2 "$UI_TX" back
    ui_choicerows "$UI_CUR"
    local a; ut "да" "yes"; a="$UI_TX"; ut "нет" "no"; local b="$UI_TX"; ut "назад" "back"; ui_keys_fit "1|$a|" "2|$b|" "0|$UI_TX|"
}

# ── Компоненты ─────────────────────────────────────────────────────────
# Данные — CA_* (apt) и CE_* (движки) из comp_apt_load / comp_engines_load;
# перерисовка на нажатие их не пересчитывает. Отметки — UI_CMARK, по id.
UI_CMARK=" "; UI_APTDIR=""; UI_APTPID=""; UI_CSEL=""
# «1.24.0-2ubuntu7.1 → …7.4»: общее начало версий не повторяем.
_ui_vshort() {  # _ui_vshort <было> <стало> → UI_P
    local a="$1" b="$2" n=0
    while [ "$n" -lt "${#a}" ] && [ "$n" -lt "${#b}" ] && [ "${a:n:1}" = "${b:n:1}" ]; do n=$(( n + 1 )); done
    if [ "$n" -gt 6 ]; then UI_P="…${b:$(( n - 2 ))}"; else UI_P="$b"; fi
}
# Строки карточки «Компоненты» в главном меню → UI_CCL.
ui_comps_cardlines() {  # ui_comps_cardlines <W>
    local W="$1" i k=0 l i2
    UI_CCL=()
    if [ "${COMP_APT:-0}" != 1 ]; then ut "apt недоступен" "apt is unavailable"; UI_CCL+=("muted${UI_US}${UI_TX}${UI_RS}")
    else
        for ((i = 0; i < ${#CA_ID[@]}; i++)); do
            [ -n "${CA_UP[$i]}" ] || continue
            if [ "$k" -ge 4 ]; then ut "и ещё" "and"; UI_CCL+=("muted${UI_US}${UI_TX} $(( UD_COMPUP - k ))…${UI_RS}"); break; fi
            UI_SEG=""; _s name "${CA_NAME[$i]} "
            if [ -n "${CA_CAND[$i]}" ]; then _ui_vshort "${CA_VER[$i]}" "${CA_CAND[$i]}"; _s text "${CA_VER[$i]}"; _s muted " → "; _s update "$UI_P"
            else l=0; for i2 in ${CA_UP[$i]}; do l=$(( l + 1 )); done; ut "пакетов: " "packages: "; _s update "↑ ${UI_TX}${l}"; fi
            ui_fit "$UI_SEG" "$W"; UI_CCL+=("$UI_FIT"); k=$(( k + 1 ))
        done
        if [ "$k" = 0 ]; then
            ut "всё актуально" "all up to date"; UI_SEG=""; _s ok "✓ "; _s text "$UI_TX"; _s muted " · $(comp_lists_label)"
            ui_fit "$UI_SEG" "$W"; UI_CCL+=("$UI_FIT")
        fi
    fi
    for l in ${COMP_BOTP[@]+"${COMP_BOTP[@]}"}; do
        IFS='|' read -r i k i2 _ <<<"$l"
        UI_SEG=""; _s err "✗ "; _s text "$i2"; ui_fit "$UI_SEG" "$W"; UI_CCL+=("$UI_FIT")
    done
    return 0
}
# Пункты экрана: строки apt, движки, действия — все выбираются стрелками.
# Первые девять строк apt отмечаются и цифрой: на телефоне стрелки неудобны.
ui_comps_items() {
    local i nm=0 a k
    ui_items_clear
    for ((i = 0; i < ${#CA_ID[@]}; i++)); do
        k=""; [ "$i" -lt 9 ] && k=$(( i + 1 ))
        ui_item "$k" "${CA_NAME[$i]}" "cmark:$i"
        case "$UI_CMARK" in *" ${CA_ID[$i]} "*) nm=$(( nm + 1 )) ;; esac
    done
    for ((i = 0; i < ${#CE_ID[@]}; i++)); do ui_item "" "${CE_NAME[$i]}" "cinfo:$i"; done
    ut "Обновить отмеченные" "Update the marked"; ui_item u "$UI_TX ($nm)" cupd
    ut "Обновить всё" "Update all"; ui_item a "$UI_TX (${COMP_NUP:-0})" call
    ut "Проверить обновления" "Check for updates"; ui_item r "$UI_TX" cref
    ut "Назад" "Back"; ui_item 0 "$UI_TX" back
    UI_CNM="$nm"
}
# Строки левого окна целиком → CL_SEG/CL_SEL, строка курсора — CL_CUR.
_ui_comps_rows() {  # _ui_comps_rows <W>
    local W="$1" i j=0 sel g gt mk
    CL_SEG=(); CL_SEL=(); CL_CUR=0
    _cl() { CL_SEG+=("$1"); CL_SEL+=("${2:-0}"); [ "${2:-0}" = 1 ] && CL_CUR=$(( ${#CL_SEG[@]} - 1 )); return 0; }
    if [ "${COMP_APT:-0}" != 1 ]; then ut "apt недоступен" "apt is unavailable"; _cl "muted${UI_US} ${UI_TX}${UI_RS}"; fi
    for ((i = 0; i < ${#CA_ID[@]}; i++)); do
        sel=0; [ "$j" = "$UI_CUR" ] && sel=1
        UI_SEG=""; _s text " "; if [ "$sel" = 1 ]; then _s cursor "▸ "; else _s cursor "  "; fi
        if [ -n "${IT_KEY[$j]:-}" ]; then if [ "$sel" = 1 ]; then _s cursor "${IT_KEY[$j]} "; else _s key "${IT_KEY[$j]} "; fi; else _s text "  "; fi
        case "$UI_CMARK" in *" ${CA_ID[$i]} "*) _s text "["; _s ok "✓"; _s text "] " ;; *) _s muted "[ ] " ;; esac
        if [ -n "${CA_UP[$i]}" ]; then g="↑"; gt=update; elif [ -n "${CA_HOLD[$i]}" ]; then g="!"; gt=warn; else g="✓"; gt=muted; fi
        ui_padr "${CA_NAME[$i]}" $(( W - 11 ))
        if [ "$sel" = 1 ]; then _s title "$UI_P"; else _s name "$UI_P"; fi
        _s "$gt" "$g"
        _cl "$UI_SEG" "$sel"; j=$(( j + 1 ))
    done
    if [ "${#CE_ID[@]}" -gt 0 ]; then
        ui_rep '─' $(( W - 2 )); _cl "rule${UI_US} ${UI_P}${UI_RS}"
        ut "ДВИЖКИ ПРОДУКТОВ" "PRODUCT ENGINES"; _cl "muted${UI_US} ${UI_TX}${UI_RS}"
        for ((i = 0; i < ${#CE_ID[@]}; i++)); do
            sel=0; [ "$j" = "$UI_CUR" ] && sel=1
            UI_SEG=""; _s text " "; if [ "$sel" = 1 ]; then _s cursor "▸ "; else _s cursor "  "; fi
            if [ "${CE_BAD[$i]}" = 1 ]; then _s err "✗ "; else _s muted "· "; fi
            ui_padr "${CE_NAME[$i]}" 15
            if [ "$sel" = 1 ]; then _s title "$UI_P"; else _s name "$UI_P"; fi
            if [ "${CE_BAD[$i]}" = 1 ]; then _s err "${CE_VER[$i]}"; else _s muted "${CE_VER[$i]}"; fi
            _cl "$UI_SEG" "$sel"; j=$(( j + 1 ))
        done
    fi
    ui_rep '─' $(( W - 2 )); _cl "rule${UI_US} ${UI_P}${UI_RS}"
    for ((i = ${#CA_ID[@]} + ${#CE_ID[@]}; i < ${#IT_KEY[@]}; i++)); do
        sel=0; [ "$j" = "$UI_CUR" ] && sel=1
        UI_SEG=""; _s text " "
        if [ "$sel" = 1 ]; then _s cursor "▸ "; _s cursor "${IT_KEY[$i]}  "; _s title "${IT_LABEL[$i]}"
        else _s cursor "  "; _s key "${IT_KEY[$i]}  "; _s name "${IT_LABEL[$i]}"; fi
        _cl "$UI_SEG" "$sel"; j=$(( j + 1 ))
    done
}
# ui_slice <высота> — CL_* в окно: срез вокруг курсора со строками «↑ ещё N» и
# «↓ ещё N». Курсор виден всегда.
ui_slice() {
    local h="$1" n="${#CL_SEG[@]}" s c top bot k
    ui_lclear
    if [ "$n" -le "$h" ]; then for ((k = 0; k < n; k++)); do ui_lpush "${CL_SEG[$k]}" "${CL_SEL[$k]}"; done; return 0; fi
    c=$(( h - 2 )); [ "$c" -ge 1 ] || c=1
    s=$(( CL_CUR - c / 2 )); [ "$s" -lt 0 ] && s=0
    for k in 1 2 3; do
        top=0; [ "$s" -gt 0 ] && top=1
        c=$(( h - top )); bot=0; [ $(( s + c )) -lt "$n" ] && { bot=1; c=$(( c - 1 )); }
        [ "$c" -ge 1 ] || c=1
        if [ "$CL_CUR" -ge $(( s + c )) ]; then s=$(( CL_CUR - c + 1 )); continue; fi
        if [ "$CL_CUR" -lt "$s" ]; then s="$CL_CUR"; continue; fi
        break
    done
    # Дошли до низа — срез сдвигается вверх, а не оставляет пустые строки.
    [ $(( s + c )) -gt "$n" ] && s=$(( n - c ))
    ut "ещё" "more"
    [ "$top" = 1 ] && ui_lpush "muted${UI_US}   ↑ ${UI_TX} ${s}${UI_RS}" 0
    for ((k = s; k < s + c; k++)); do ui_lpush "${CL_SEG[$k]}" "${CL_SEL[$k]}"; done
    [ "$bot" = 1 ] && ui_lpush "muted${UI_US}   ↓ ${UI_TX} $(( n - s - c ))${UI_RS}" 0
    return 0
}
_ui_b_comps_list() { _ui_comps_rows "$1"; ui_slice "${UI_CLH:-17}"; }
# Правое окно — карточка строки под курсором.
_ui_comps_lab() {  # _ui_comps_lab <ru> <en> → UI_P: подпись колонки
    ut "$1" "$2"; ui_padr "$UI_TX" 10
}
_ui_b_comps_card() {
    local W="$1" a="${IT_ACT[$UI_CUR]:-}" i l k e w=$(( $1 - 12 )) H="${UI_CCH:-17}" foot=""
    ui_lclear
    _C() { ui_lpush "text${UI_US} ${UI_RS}$1" 0; }
    case "$a" in
        cmark:*)
            i="${a#cmark:}"
            ui_wrap "${CA_WHAT[$i]}" $(( W - 2 )); for l in "${UI_WRAP[@]}"; do _C "muted${UI_US}${l}${UI_RS}"; done
            _C ""
            _ui_comps_lab "СТОИТ" "INSTALLED"
            if [ "${CA_ID[$i]}" = tools ]; then ut "пакетов" "packages"; _C "muted${UI_US}${UI_P}${UI_RS}text${UI_US}${CA_N[$i]} ${UI_TX}${UI_RS}"
            else _C "muted${UI_US}${UI_P}${UI_RS}text${UI_US}${CA_VER[$i]}${UI_RS}"; fi
            _ui_comps_lab "ДОСТУПНО" "AVAILABLE"; l="$UI_P"
            if [ -n "${CA_UP[$i]}" ]; then
                if [ -n "${CA_CAND[$i]}" ]; then e="↑ ${CA_CAND[$i]}"
                else ut "из" "of"; e="↑ ${CA_UPN[$i]:-?} ${UI_TX} ${CA_N[$i]}"; fi
                _C "muted${UI_US}${l}${UI_RS}update${UI_US}${e}${UI_RS}"
            elif [ -n "${CA_HOLD[$i]}" ] && [ -n "${CA_MAIN[$i]}" ] && case " ${CA_HOLD[$i]} " in *" ${CA_MAIN[$i]} "*) true ;; *) false ;; esac; then
                ut "! закреплён (apt-mark hold)" "! held (apt-mark hold)"; _C "muted${UI_US}${l}${UI_RS}warn${UI_US}${UI_TX}${UI_RS}"
            else ut "✓ новее нет" "✓ nothing newer"; _C "muted${UI_US}${l}${UI_TX}${UI_RS}"; fi
            _ui_comps_lab "ДЛЯ" "FOR"; l="$UI_P"
            ui_wrap "${CA_PROD[$i]}" "$w"; k=0
            for e in "${UI_WRAP[@]}"; do
                if [ "${CA_PRODM[$i]}" = 1 ]; then _C "muted${UI_US}${l}${e}${UI_RS}"; else _C "muted${UI_US}${l}${UI_RS}text${UI_US}${e}${UI_RS}"; fi
                ui_padr "" 10; l="$UI_P"
            done
            if [ -n "${CA_UP[$i]}" ]; then
                _ui_comps_lab "ПАКЕТЫ" "PACKAGES"; l="$UI_P"
                ui_wrap "$(comp_pkgs "$i")" "$w"; k=0
                for e in "${UI_WRAP[@]}"; do [ "$k" -lt 3 ] || break; _C "muted${UI_US}${l}${UI_RS}text${UI_US}${e}${UI_RS}"; ui_padr "" 10; l="$UI_P"; k=$(( k + 1 )); done
            fi
            if [ -n "${CA_NOTE[$i]}" ]; then
                ut "ПРИ ОБНОВЛЕНИИ" "ON UPDATE"; _C "muted${UI_US}${UI_TX}${UI_RS}"
                ui_wrap "${CA_NOTE[$i]}" $(( W - 4 )); for e in "${UI_WRAP[@]}"; do _C "text${UI_US}  ${e}${UI_RS}"; done
            fi
            if [ -n "${CA_HOLD[$i]}" ]; then
                ut "! закреплён (apt-mark hold): " "! held (apt-mark hold): "
                ui_wrap "${UI_TX}${CA_HOLD[$i]}" $(( W - 2 )); for e in "${UI_WRAP[@]}"; do _C "warn${UI_US}${e}${UI_RS}"; done
            fi
            UI_SEG=""; ut "Пробел или Enter" "Space or Enter"; _s key "$UI_TX"; ut " — отметить" " — mark"; _s muted "$UI_TX"; foot="$UI_SEG" ;;
        cinfo:*)
            i="${a#cinfo:}"
            _ui_comps_lab "ВЕРСИЯ" "VERSION"
            if [ "${CE_BAD[$i]}" = 1 ]; then _C "muted${UI_US}${UI_P}${UI_RS}err${UI_US}✗ ${CE_VER[$i]}${UI_RS}"
                ui_wrap "${CE_MSG[$i]}" "$w"; for e in "${UI_WRAP[@]}"; do ui_padr "" 10; _C "muted${UI_US}${UI_P}${UI_RS}err${UI_US}${e}${UI_RS}"; done
            else _C "muted${UI_US}${UI_P}${UI_RS}text${UI_US}${CE_VER[$i]}${UI_RS}"; fi
            _ui_comps_lab "ПРОДУКТ" "PRODUCT"; _C "muted${UI_US}${UI_P}${UI_RS}text${UI_US}${CE_PROD[$i]}${UI_RS}"
            if [ "${CE_BAD[$i]}" = 1 ]; then _ui_comps_lab "ПОЧИНИТЬ" "TO FIX"; else _ui_comps_lab "ОБНОВЛЯЕТ" "UPDATED BY"; fi; l="$UI_P"
            ui_wrap "${CE_HINT[$i]}" "$w"
            for e in "${UI_WRAP[@]}"; do _C "muted${UI_US}${l}${UI_RS}text${UI_US}${e}${UI_RS}"; ui_padr "" 10; l="$UI_P"; done
            ut "обновляет продукт, не goInstaller" "the product updates it, not goInstaller"; foot="muted${UI_US}${UI_TX}${UI_RS}" ;;
        cupd|call)
            if [ "$a" = cupd ]; then ut "Обновит отмеченные:" "Updates the marked ones:"; else ut "Обновит всё, где есть новее:" "Updates everything with a newer version:"; fi
            _C "muted${UI_US}${UI_TX}${UI_RS}"; k=0
            for ((i = 0; i < ${#CA_ID[@]}; i++)); do
                if [ "$a" = cupd ]; then case "$UI_CMARK" in *" ${CA_ID[$i]} "*) ;; *) continue ;; esac; else [ -n "${CA_UP[$i]}" ] || continue; fi
                UI_SEG=""; _s name "${CA_NAME[$i]} "
                if [ -n "${CA_CAND[$i]}" ]; then _ui_vshort "${CA_VER[$i]}" "${CA_CAND[$i]}"; _s text "${CA_VER[$i]}"; _s muted " → "; _s update "$UI_P"
                elif [ -n "${CA_UP[$i]}" ]; then ut "пакеты группы" "group packages"; _s update "↑ $UI_TX"
                else ut "новее нет" "nothing newer"; _s muted "$UI_TX"; fi
                _C "$UI_SEG"; k=$(( k + 1 ))
            done
            if [ "$k" = 0 ]; then
                if [ "$a" = cupd ]; then ut "ничего не отмечено: Пробел или Enter на строке компонента" "nothing marked: Space or Enter on a component row"; else ut "обновлять нечего" "nothing to update"; fi
                ui_wrap "$UI_TX" $(( W - 2 )); for e in "${UI_WRAP[@]}"; do _C "muted${UI_US}${e}${UI_RS}"; done
            fi
            _C ""; ut "Сначала пробный прогон apt, потом вопрос 1 Да / 2 Нет." "A dry apt run first, then the question 1 Yes / 2 No."
            ui_wrap "$UI_TX" $(( W - 2 )); for e in "${UI_WRAP[@]}"; do _C "muted${UI_US}${e}${UI_RS}"; done ;;
        cref)
            ut "apt-get update: свежие списки пакетов, не дольше 180 с. Вывод — в журнал:" "apt-get update: fresh package lists, at most 180 s. The output goes to the log:"
            ui_wrap "$UI_TX" $(( W - 2 )); for e in "${UI_WRAP[@]}"; do _C "muted${UI_US}${e}${UI_RS}"; done
            _C "text${UI_US}${GOINST_DIR}/logs${UI_RS}"; _C ""; _C "muted${UI_US}$(comp_lists_label)${UI_RS}" ;;
        *)  ut "вернуться в главное меню" "back to the main menu"; _C "muted${UI_US}${UI_TX}${UI_RS}" ;;
    esac
    while [ "${#UI_LS[@]}" -lt $(( H - 1 )) ]; do ui_lpush "" 0; done
    UI_LS=("${UI_LS[@]:0:$(( H - 1 ))}"); UI_LSEL=("${UI_LSEL[@]:0:$(( H - 1 ))}")
    ui_lpush "text${UI_US} ${UI_RS}$foot" 0
}
# Одно окно (уже 80): три строки о выбранном, черта, срез списка.
_ui_b_comps46() {
    local W="$1" a="${IT_ACT[$UI_CUR]:-}" i e hc=0 lines=()
    _c46() { lines+=("text${UI_US} ${UI_RS}$1"); }
    case "$a" in
        cmark:*) i="${a#cmark:}"
            UI_SEG=""; _s title "${CA_NAME[$i]}  "; if [ "${CA_ID[$i]}" = tools ]; then ut "пакетов" "packages"; _s text "${CA_N[$i]} $UI_TX"; else _s text "${CA_VER[$i]}"; fi; _c46 "$UI_SEG"
            if [ -n "${CA_UP[$i]}" ]; then _c46 "update${UI_US}↑ ${CA_CAND[$i]:-$(comp_pkgs "$i")}${UI_RS}"
            elif [ -n "${CA_HOLD[$i]}" ]; then ut "! закреплён (apt-mark hold)" "! held (apt-mark hold)"; _c46 "warn${UI_US}${UI_TX}${UI_RS}"
            else ut "✓ новее нет" "✓ nothing newer"; _c46 "muted${UI_US}${UI_TX}${UI_RS}"; fi
            _c46 "muted${UI_US}${CA_PROD[$i]}${UI_RS}" ;;
        cinfo:*) i="${a#cinfo:}"
            UI_SEG=""; _s title "${CE_FULL[$i]}  "; if [ "${CE_BAD[$i]}" = 1 ]; then _s err "✗ ${CE_VER[$i]}"; else _s text "${CE_VER[$i]}"; fi; _c46 "$UI_SEG"
            _c46 "muted${UI_US}${CE_PROD[$i]}${UI_RS}"; ui_wrap "${CE_HINT[$i]}" $(( W - 2 )); _c46 "muted${UI_US}${UI_WRAP[0]:-}${UI_RS}" ;;
        *) _c46 "title${UI_US}${IT_LABEL[$UI_CUR]:-}${UI_RS}"; _c46 "muted${UI_US}$(comp_lists_label)${UI_RS}" ;;
    esac
    ui_rep '─' $(( W - 2 )); lines+=("rule${UI_US} ${UI_P}${UI_RS}")
    _ui_comps_rows "$W"
    ui_slice $(( ${UI_CLH46:-18} - ${#lines[@]} ))
    UI_LS=("${lines[@]}" ${UI_LS[@]+"${UI_LS[@]}"})
    for ((i = 0; i < ${#lines[@]}; i++)); do UI_LSEL=(0 ${UI_LSEL[@]+"${UI_LSEL[@]}"}); done
}
ui_scr_comps() {  # ui_scr_comps <cur>
    local rt a
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_comps_items
    [ "$UI_CUR" -lt "${#IT_KEY[@]}" ] || UI_CUR=0
    UI_CLH=$(( 17 + UI_R - 24 )); UI_CCH="$UI_CLH"; UI_CLH46=$(( UI_R - 6 ))
    comp_lists_when
    if [ -n "${UI_APTDIR:-}" ]; then ut "проверяю обновления" "checking for updates"; rt="cursor${UI_US}${UI_SPIN:-⠋} ${UI_RS}muted${UI_US}${UI_TX}${UI_RS}"
    else rt="muted${UI_US}$(comp_lists_label)${UI_RS}"; fi
    ut "КОМПОНЕНТЫ" "COMPONENTS"; SH_LW=34; SH_LTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_LBUILD=_ui_b_comps_list
    a="${IT_ACT[$UI_CUR]:-}"
    case "$a" in
        cmark:*) SH_RTITLE="title${UI_US}${CA_NAME[${a#cmark:}]}${UI_RS}" ;;
        cinfo:*) SH_RTITLE="title${UI_US}${CE_FULL[${a#cinfo:}]}${UI_RS}" ;;
        *) SH_RTITLE="title${UI_US}${IT_LABEL[$UI_CUR]}${UI_RS}" ;;
    esac
    SH_RRIGHT="$rt"; SH_RBUILD=_ui_b_comps_card; SH_RBUILD46=_ui_b_comps46
    if [ "$UI_C" -lt 80 ]; then SH_RTITLE="title${UI_US}${UI_TX}${UI_RS}"; SH_RRIGHT46="$rt"; fi
    ui_shell2
    local b c d e f
    ut "выбрать" "move"; a="$UI_TX"; ut "Пробел" "Space"; b="$UI_TX"; ut "отметить" "mark"; c="$UI_TX"
    ut "отмеченные" "marked"; d="$UI_TX"; ut "всё" "all"; e="$UI_TX"; ut "проверить" "check"; f="$UI_TX"; ut "назад" "back"
    ui_keys_fit "↑↓|$a|" "$b 1-9|$c|" "u|$d|" "a|$e|" "r|$f|" "0|$UI_TX|$UI_TX"
}
# Подтверждение: что обновится по пробному прогону, вопрос цифрой.
ui_scr_compconfirm() {  # ui_scr_compconfirm <cur>
    local i e n=0 M=() R=() l max
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "Обновить компоненты" "Update the components"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "$(comp_lists_label)"; ui_body ""
    for i in $UI_CSEL; do
        UI_SEG=""; ui_padr "${CA_NAME[$i]}" 14; _s name "  $UI_P"
        if [ -n "${CA_CAND[$i]}" ]; then _s text "${CA_VER[$i]}"; _s muted " → "; _s update "${CA_CAND[$i]}"
        else ut "пакеты группы" "group packages"; _s update "↑ $UI_TX"; fi
        M+=("$UI_SEG")
    done
    M+=("")
    if [ -n "$COMP_DRY_ERR" ]; then
        ut "Пробный прогон apt не прошёл:" "The apt dry run failed:"
        ui_wrap "$UI_TX $COMP_DRY_ERR" $(( UI_C - 6 )); for l in "${UI_WRAP[@]}"; do M+=("err${UI_US}  ${l}${UI_RS}"); done
    else
        for e in $COMP_DRY_INST; do n=$(( n + 1 )); done
        ut "apt обновит пакетов: " "apt will upgrade packages: "; M+=("text${UI_US}  ${UI_TX}${UI_RS}title${UI_US}${n}${UI_RS}")
        # Не больше двух строк имён; не влезли — «и ещё N», а не молча.
        ui_wrap "$COMP_DRY_INST" $(( UI_C - 6 ))
        if [ "${#UI_WRAP[@]}" -gt 2 ]; then
            local -a pk=($COMP_DRY_INST); local k
            for ((k = ${#pk[@]} - 1; k > 0; k--)); do
                ut "и ещё $(( ${#pk[@]} - k ))" "and $(( ${#pk[@]} - k )) more"
                ui_wrap "${pk[*]:0:k} ${UI_TX}" $(( UI_C - 6 ))
                [ "${#UI_WRAP[@]}" -le 2 ] && break
            done
        fi
        for ((e = 0; e < ${#UI_WRAP[@]} && e < 2; e++)); do M+=("muted${UI_US}    ${UI_WRAP[$e]}${UI_RS}"); done
        if [ -n "$COMP_DRY_KEPT" ]; then ut "отложено: " "held back: "; ui_wrap "${UI_TX}${COMP_DRY_KEPT}" $(( UI_C - 6 )); for l in "${UI_WRAP[@]}"; do M+=("warn${UI_US}  ${l}${UI_RS}"); done; fi
        for i in $UI_CSEL; do
            [ -n "${CA_NOTE[$i]}" ] || continue
            ui_wrap "${CA_NAME[$i]}: ${CA_NOTE[$i]}" $(( UI_C - 8 ))
            e=0; for l in "${UI_WRAP[@]}"; do if [ "$e" = 0 ]; then M+=("warn${UI_US}  ! ${UI_RS}muted${UI_US}${l}${UI_RS}"); else M+=("muted${UI_US}    ${l}${UI_RS}"); fi; e=1; done
        done
        # Перезапуск служб — всегда на экране: обрезается то, что над ним.
        [ "$n" -gt 0 ] && { ui_wrap "$(comp_restart_note)" $(( UI_C - 8 )); e=0; for l in "${UI_WRAP[@]}"; do if [ "$e" = 0 ]; then R+=("warn${UI_US}  ! ${UI_RS}muted${UI_US}${l}${UI_RS}"); else R+=("muted${UI_US}    ${l}${UI_RS}"); fi; e=1; done; }
    fi
    # Вопрос и пункты должны остаться на экране: лишнее сверху обрезаем.
    max=$(( UI_R - 2 - 3 - 7 - ${#R[@]} ))
    if [ "${#M[@]}" -gt "$max" ]; then M=("${M[@]:0:$(( max - 1 ))}"); M+=("muted${UI_US}  …${UI_RS}"); fi
    for l in "${M[@]}" ${R[@]+"${R[@]}"}; do ui_body "$l"; done
    ui_body ""
    ui_items_clear
    if [ -z "$COMP_DRY_ERR" ] && [ "$n" -gt 0 ]; then
        ut "Запустить обновление?" "Run the update?"; ui_body "title${UI_US}  ${UI_TX}${UI_RS}"
        ut "Да" "Yes"; ui_body "muted${UI_US}  Enter — 1, ${UI_TX}${UI_RS}"; ui_body ""
        ut "Да" "Yes"; ui_item 1 "$UI_TX" cyes; ut "Нет" "No"; ui_item 2 "$UI_TX" back
    else
        [ -z "$COMP_DRY_ERR" ] && { ut "apt ничего не обновит." "apt will upgrade nothing."; ui_body "muted${UI_US}  ${UI_TX}${UI_RS}"; ui_body ""; }
        ut "Назад" "Back"; ui_item 0 "$UI_TX" back
    fi
    ui_choicerows "$UI_CUR"
    local a b; ut "да" "yes"; a="$UI_TX"; ut "нет" "no"; b="$UI_TX"; ut "назад" "back"; ui_keys_fit "1|$a|" "2|$b|" "0|$UI_TX|"
}
# Войти на экран: свежие сведения; списки старше 12 часов — проверить в фоне.
ui_comps_open() {
    comp_apt_load >/dev/null 2>&1; comp_engines_load; UD_COMPUP="${COMP_NUP:-0}"
    ui_go comps 0
    [ "${COMP_APT:-0}" = 1 ] && comp_autocheck_due && ui_comp_refresh_start
    return 0
}
# ── «Аркада»: защита от сканеров — макет design/shield/handoff-stats ──
# Экраны sh-d (меню «Защита»), sh-e (статистика), sh-g (топ-30), sh-h
# (настройки статистики), карточка s главного меню. Числа — из _shield_spy ui
# (только чтение), разметка — клетка в клетку с shield-screens.js.

# ui_nf <число> → UI_P: разряды через пробел (en — запятая), как nf() макета.
ui_nf() {
    local n="$1" s="" sep=" "
    [ "${LANG_CODE:-ru}" = en ] && sep=","
    case "$n" in ''|*[!0-9]*) UI_P="$n"; return 0 ;; esac
    while [ "${#n}" -gt 3 ]; do s="$sep${n: -3}$s"; n="${n:0:${#n}-3}"; done
    UI_P="$n$s"
}
# ui_nfs <число> → UI_P: до 99 999 — как ui_nf, дальше коротко, с округлением вниз:
# «125 тыс.», «1,2 млн», «12 млн», «1,2 млрд» (en «125k», «1.2M», «12M», «1.2B»).
ui_nfs() {
    local n="$1" d="," s u q
    case "$n" in ''|*[!0-9]*) UI_P="$n"; return 0 ;; esac
    [ "${#n}" -le 18 ] || { UI_P="$n"; return 0; }
    n=$(( 10#$n ))
    [ "$n" -lt 100000 ] && { ui_nf "$n"; return 0; }
    [ "${LANG_CODE:-ru}" = en ] && d="."
    if [ "$n" -lt 1000000 ]; then
        UI_P="$(( n / 1000 ))"; if [ "$d" = . ]; then UI_P+="k"; else UI_P+=" тыс."; fi; return 0
    fi
    if [ "$n" -lt 1000000000 ]; then u=1000000; s=" млн"; [ "$d" = . ] && s="M"
    else u=1000000000; s=" млрд"; [ "$d" = . ] && s="B"; fi
    q=$(( n / u ))
    if [ "$q" -lt 10 ]; then UI_P="$q$d$(( n % u * 10 / u ))$s"; else ui_nf "$q"; UI_P+="$s"; fi
}
# ui_padn <текст> <ширина> → UI_P: прижать вправо, длинное — как есть (без «…»).
ui_padn() {
    local s="$1" n="$2"
    if [ "${#s}" -ge "$n" ]; then UI_P="$s"; else printf -v UI_P '%*s%s' "$(( n - ${#s} ))" '' "$s"; fi
}
# ui_dec <десятые> → UI_P: «2,8» (en «2.8»).
ui_dec() { local d=","; [ "${LANG_CODE:-ru}" = en ] && d="."; UI_P="$(( $1 / 10 ))$d$(( $1 % 10 ))"; }
# ui_pl <n> <1> <2–4> <5+> <en 1> <en N> → UI_P: слово в нужной форме.
ui_pl() {
    local n="$1" d h
    if [ "${LANG_CODE:-ru}" = en ]; then if [ "$n" = 1 ]; then UI_P="$5"; else UI_P="$6"; fi; return 0; fi
    d=$(( n % 10 )); h=$(( n % 100 ))
    if [ "$d" = 1 ] && [ "$h" != 11 ]; then UI_P="$2"
    elif [ "$d" -ge 2 ] && [ "$d" -le 4 ] && { [ "$h" -lt 12 ] || [ "$h" -gt 14 ]; }; then UI_P="$3"
    else UI_P="$4"; fi
}
# ui_padl / ui_padc <текст> <ширина> → UI_P: прижать вправо / по центру.
ui_padl() {
    local s="$1" n="$2"
    if [ "${#s}" -gt "$n" ]; then UI_P="${s:0:$(( n - 1 ))}…"
    else printf -v UI_P '%*s%s' "$(( n - ${#s} ))" '' "$s"; fi
}
ui_padc() {
    local s="$1" n="$2" l
    if [ "${#s}" -ge "$n" ]; then UI_P="${s:0:$n}"; return 0; fi
    l=$(( (n - ${#s}) / 2 ))
    printf -v UI_P '%*s%s%*s' "$l" '' "$s" "$(( n - ${#s} - l ))" ''
}
# ui_wrapk <текст> <ширина> [слово] → UI_WRAP: перенос, «·» держится за
# словом слева, слово (ссылка) — всегда с новой строки (wrap макета).
ui_wrapk() {
    local w="$2" keep="${3:-}" word line=""
    local -a ws=() wl=()
    read -r -a wl <<<"$1"
    for word in ${wl[@]+"${wl[@]}"}; do
        if [ "$word" = "·" ] && [ "${#ws[@]}" -gt 0 ]; then ws[${#ws[@]}-1]+=" ·"; else ws+=("$word"); fi
    done
    UI_WRAP=()
    for word in ${ws[@]+"${ws[@]}"}; do
        if [ -z "$line" ]; then line="$word"
        elif [ "$word" != "$keep" ] && [ $(( ${#line} + 1 + ${#word} )) -le "$w" ]; then line+=" $word"
        else UI_WRAP+=("$line"); line="$word"; fi
    done
    [ -n "$line" ] && UI_WRAP+=("$line")
    return 0
}
ui_sh_wd() {  # ui_sh_wd <0 — вс> → UI_P
    local -a a
    if [ "${LANG_CODE:-ru}" = en ]; then a=(Su Mo Tu We Th Fr Sa); else a=(вс пн вт ср чт пт сб); fi
    UI_P="${a[$1]:-?}"
}
ui_sh_mon() {  # ui_sh_mon <1–12> → UI_P
    local -a a
    if [ "${LANG_CODE:-ru}" = en ]; then a=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    else a=(янв фев мар апр май июн июл авг сен окт ноя дек); fi
    UI_P="${a[$(( $1 - 1 ))]:-?}"
}
# Подпись дня (dlab макета): «вт 03.11» / «Tu 3 Nov» от 80 колонок, уже — «вт 03».
ui_sh_dlab3() {  # ui_sh_dlab3 <dd> <mm> <день недели> <C> → UI_P
    local w
    ui_sh_wd "$3"; w="$UI_P"
    if [ "$4" -lt 80 ]; then UI_P="$w $1"
    elif [ "${LANG_CODE:-ru}" = en ]; then ui_sh_mon $(( 10#$2 )); UI_P="$w $(( 10#$1 )) $UI_P"
    else UI_P="$w $1.$2"; fi
}
ui_sh_dlab() { ui_sh_dlab3 "${SM_DD[$1]}" "${SM_DM[$1]}" "${SM_DW[$1]}" "$2"; }

# Число из модели: только цифры, не длиннее 15 знаков (чужой файл).
_smn() { case "$1" in ''|*[!0-9]*) UI_P=0 ;; *) if [ "${#1}" -le 15 ]; then UI_P=$(( 10#$1 )); else UI_P=0; fi ;; esac; }
# ui_sh_model → SM_*: числа статистики для экранов. SM_OK=1 — данные есть.
# Сами числа считает _shield_spy ui (только чтение stats/); в тесте модель
# берётся из файла GOINST_SHIELD_UIMODEL. Python по всему stats/ — не на каждом
# входе в «Защиту» и опросе меню: вывод помнится (UI_SHSRC), пока не сменились
# файлы stats/ (снимок — раз в час), час и сведения портов (ключ UI_SHKEY).
ui_sh_model() {
    local src="" info key k a b c d e f g h i p j
    SM_OK=0; SM_LV=-; SM_ST=""; SM_STT=""; SM_ND=0; SM_BY=0; SM_NA=0
    SM_IN=(0 0 0 0); SM_AD=(0 0 0 0); SM_OUT=(0 0 0 0); SM_NW=(- - - -); SM_RP=(- - - -)
    SM_HH=(); SM_HI=(); SM_HO=(); SM_DD=(); SM_DM=(); SM_DW=(); SM_DI=(); SM_DO=()
    SM_MM=(); SM_MY=(); SM_MI=(); SM_MO=()
    SM_PKV=(0 0 0 0); SM_PKX=(-1 -1 -1 -1); SM_PKS=(0 0 0 0); SM_PKA=("" "" "" "")
    SM_PN=(0 0 0 0); SM_PP=(); SM_PV=(); SM_PL=()
    SM_TN=(0 0 0 0); SM_TA=(); SM_TB=(); SM_TS=(); SM_TL=(); SM_TO=(); SM_TM=()
    if [ -n "${GOINST_TEST:-}" ] && [ -n "${GOINST_SHIELD_UIMODEL:-}" ]; then
        src=$(cat "$GOINST_SHIELD_UIMODEL" 2>/dev/null) || src=""
    else
        command -v python3 >/dev/null 2>&1 || return 0
        _shield_has_stats || return 0
        # Путь — в UI_SHTMP: Ctrl+C во время python уберёт файл ui_crash_exit.
        info=$(mktemp "${TMPDIR:-/tmp}/goinst-stats.XXXXXX") || return 0
        UI_SHTMP="$info"
        with_scan_cache _shield_stats_info "$info"
        k=$(_shield_now)
        key="${LANG_CODE:-ru}|$(( k / 3600 ))|$(stat -c '%Y.%i.%s' "$SHIELD_STATS" "$SHIELD_STATS"/* 2>/dev/null || stat -f '%m.%i.%z' "$SHIELD_STATS" "$SHIELD_STATS"/* 2>/dev/null)|$(cat "$info" 2>/dev/null)"
        if [ -n "${UI_SHSRC:-}" ] && [ "$key" = "${UI_SHKEY:-}" ]; then src="$UI_SHSRC"
        else
            src=$(_shield_spy ui "$SHIELD_STATS" "$info" "$k" 2>/dev/null) || src=""
            UI_SHKEY="$key"; UI_SHSRC="$src"
        fi
        rm -f "$info"; UI_SHTMP=""
    fi
    [ -n "$src" ] || return 0
    _smp() { case "$1" in 24h) p=0 ;; 7d) p=1 ;; 30d) p=2 ;; all) p=3 ;; *) p="" ;; esac; }
    while IFS='|' read -r k a b c d e f g h i; do
        case "$k" in
            g)  case "$a" in [0-9]) SM_LV="$a" ;; *) SM_LV=- ;; esac
                [[ "$b" =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]{4}$ ]] && SM_ST="$b"
                [[ "$c" =~ ^[0-9]{2}:[0-9]{2}$ ]] && SM_STT="$c"
                _smn "$d"; SM_ND=$UI_P; _smn "$e"; SM_BY=$UI_P; _smn "$f"; SM_NA=$UI_P ;;
            per) _smp "$a"; [ -n "$p" ] || continue
                _smn "$b"; SM_IN[p]=$UI_P; _smn "$c"; SM_AD[p]=$UI_P; _smn "$d"; SM_OUT[p]=$UI_P
                if [ "$e" = - ]; then SM_NW[p]=-; else _smn "$e"; SM_NW[p]=$UI_P; fi
                if [ "$f" = - ]; then SM_RP[p]=-; else _smn "$f"; SM_RP[p]=$UI_P; fi ;;
            h)  [[ "$a" =~ ^[0-9]{2}$ ]] || continue
                SM_HH+=("$a"); _smn "$b"; SM_HI+=("$UI_P"); _smn "$c"; SM_HO+=("$UI_P") ;;
            d)  [[ "$a$b" =~ ^[0-9]{4}$ ]] && [[ "$c" =~ ^[0-6]$ ]] || continue
                SM_DD+=("$a"); SM_DM+=("$b"); SM_DW+=("$c"); _smn "$d"; SM_DI+=("$UI_P"); _smn "$e"; SM_DO+=("$UI_P") ;;
            m)  [[ "$a" =~ ^[0-9]{1,2}$ ]] && [ "$a" -ge 1 ] && [ "$a" -le 12 ] && [[ "$b" =~ ^[0-9]{4}$ ]] || continue
                SM_MM+=("$a"); SM_MY+=("$b"); _smn "$c"; SM_MI+=("$UI_P"); _smn "$d"; SM_MO+=("$UI_P") ;;
            pk) _smp "$a"; [ -n "$p" ] || continue
                _smn "$b"; SM_PKV[p]=$UI_P
                if [ "$c" = -1 ]; then SM_PKX[p]=-1; else _smn "$c"; SM_PKX[p]=$UI_P; fi
                [ "$d" = 1 ] && SM_PKS[p]=1
                case "$p" in
                    0) [[ "$e" =~ ^[0-9]{2}$ ]] && SM_PKA[p]="$e" ;;
                    1|2) [[ "$e$f" =~ ^[0-9]{4}$ ]] && [[ "$g" =~ ^[0-6]$ ]] && SM_PKA[p]="$e|$f|$g" ;;
                    3) [[ "$e" =~ ^[0-9]{1,2}$ ]] && [ "$e" -ge 1 ] && [ "$e" -le 12 ] && [[ "$f" =~ ^[0-9]{4}$ ]] && SM_PKA[p]="$e|$f" ;;
                esac ;;
            pt) _smp "$a"; [ -n "$p" ] || continue
                [[ "$b" =~ ^[0-9]{1,5}/(tcp|udp)$ ]] && [ "${SM_PN[p]}" -lt 4 ] || continue
                j=$(( p * 4 + SM_PN[p] )); SM_PP[j]="$b"; _smn "$c"; SM_PV[j]=$UI_P
                SM_PL[j]="${d//[$'\001'-$'\037'$'\177']/}"; SM_PN[p]=$(( SM_PN[p] + 1 )) ;;
            t)  _smp "$a"; [ -n "$p" ] || continue
                [ "${SM_TN[p]}" -lt 30 ] || continue
                j=$(( p * 30 + SM_TN[p] ))
                _smn "$c"; SM_TA[j]=$UI_P; _smn "$d"; SM_TB[j]=$UI_P; _smn "$e"; SM_TS[j]=$UI_P
                if [[ "$f" =~ ^[0-9]{2}\.[0-9]{2}$ ]] && [[ "$g" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then SM_TL[j]="$f $g"; else SM_TL[j]=""; fi
                if [[ "$h" =~ ^[0-9]{1,5}/(tcp|udp)$ ]]; then SM_TO[j]="$h"; else SM_TO[j]=""; fi
                SM_TM[j]="${i//[$'\001'-$'\037'$'\177']/}"; SM_TN[p]=$(( SM_TN[p] + 1 )) ;;
        esac
    done <<<"$src"
    case "$SM_LV" in [1-9]) [ "${#SM_HH[@]}" = 24 ] && [ "${#SM_DD[@]}" = 30 ] && SM_OK=1 ;; esac
    return 0
}
# Защита стоит (есть что показать на экранах из макета).
ui_sh_inst() { case "${SHS_ST:-none}" in ok|off|bad) return 0 ;; esac; return 1; }
# Счётчики и спарклайн в главном меню: защита работает (вкл или выкл) и
# числа есть. Не работает — «✓» у счётчиков врал бы; об этом говорит тревога.
ui_sh_live() { case "${SHS_ST:-none}" in ok|off) [ "${SM_OK:-0}" = 1 ] ;; *) return 1 ;; esac; }
# Тревоги (не работает, список отклонён, не скачалось) → UI_SHA, по ширине.
ui_sh_alarms() {  # ui_sh_alarms <ширина>
    local w="$1" l t
    UI_SHA=()
    _sha() { ui_wrap "$2" "$w"; for l in "${UI_WRAP[@]}"; do UI_SHA+=("$1${UI_US}$l${UI_RS}"); done; }
    [ "${SHS_ST:-}" = bad ] && { ut "✗ Не работает:" "✗ Not working:"; _sha err "$UI_TX ${SHS_WHY}"; }
    [ -n "${SHS_REJ:-}" ] && { ut "! Последний список отклонён:" "! The last list was rejected:"; _sha warn "$UI_TX ${SHS_REJ}"; }
    [ -n "${SHS_UPDERR:-}" ] && { ut "! Последнее обновление не скачалось:" "! The last update did not download:"; _sha warn "$UI_TX ${SHS_UPDERR}"; }
    if [ -n "${SHS_VKREJ:-}" ]; then
        ut "Список ВК отклонён" "The VK list was rejected"
        if [ "${SHS_VK:-0}" = 1 ]; then _sha warn "! $UI_TX$(_shield_vkrej_tail): ${SHS_VKREJ}"
        else _sha muted "$UI_TX$(_shield_vkrej_tail): ${SHS_VKREJ}"; fi
    fi
    return 0
}
# Карточка с графиком: защита стоит, данные есть, тревог нет.
ui_sh_cardok() {
    ui_sh_inst && [ "${SM_OK:-0}" = 1 ] && [ "${SHS_ST:-}" != bad ] && [ -z "${SHS_REJ:-}" ] && [ -z "${SHS_UPDERR:-}" ] && [ -z "${SHS_VKREJ:-}" ]
}
# Текст вместо графика, когда чисел нет.
ui_sh_nodata() {
    if [ "${SM_LV:-}" = 0 ]; then ut "Статистики не будет: nft или ядро не умеют счётчиков." "No statistics: nft or the kernel cannot count."
    else ut "Статистики ещё нет: счётчики снимаются раз в час." "No statistics yet: counters are read once an hour."; fi
}

# ── «бабочка»: вход влево, выход вправо, подписи по центру ──
# ui_sh_nice <макс> → NM_MAX, NM_ST: круглый верх шкалы, шаг 1/2/5, не больше 4 делений.
ui_sh_nice() {
    local mx="$1" k m st n p=1
    [ "$mx" -lt 1 ] && mx=1
    for ((k = 0; k < 8; k++)); do
        for m in 1 2 5; do
            st=$(( m * p )); n=$(( (mx + st - 1) / st ))
            if [ "$n" -le 4 ]; then NM_MAX=$(( n * st )); NM_ST=$st; return 0; fi
        done
        p=$(( p * 10 ))
    done
    NM_MAX=$mx; NM_ST=$mx
}
# ui_sh_side <значение> <W> <верх> <шаг> <1 — левая> → UI_P: полоса с сеткой ┊.
ui_sh_side() {
    local v="$1" W="$2" mx="$3" st="$4" left="$5" g j h full i tk pt="" pc="" out=""
    local -a A=() T=()
    for ((i = 0; i < W; i++)); do A[i]=' '; T[i]=text; done
    for ((g = st; g < mx; g += st)); do
        j=$(( (2 * g * W + mx) / (2 * mx) - 1 ))
        if [ "$j" -ge 0 ] && [ "$j" -lt "$W" ]; then A[j]='┊'; T[j]=shadow; fi
    done
    if [ "$left" = 1 ]; then tk=in; else tk=out; fi
    h=$(( (4 * v * W + mx) / (2 * mx) )); full=$(( h / 2 ))
    for ((i = 0; i < full && i < W; i++)); do A[i]='█'; T[i]=$tk; done
    if [ $(( h % 2 )) = 1 ] && [ "$full" -lt "$W" ]; then if [ "$left" = 1 ]; then A[full]='▐'; else A[full]='▌'; fi; T[full]=$tk; fi
    if [ "$v" -gt 0 ] && [ "$h" = 0 ]; then if [ "$left" = 1 ]; then A[0]='▕'; else A[0]='▏'; fi; T[0]=$tk; fi
    for ((i = 0; i < W; i++)); do
        if [ "$left" = 1 ]; then j=$(( W - 1 - i )); else j=$i; fi
        if [ "${T[j]}" = "$pt" ]; then pc+="${A[j]}"
        else [ -n "$pt" ] && out+="$pt${UI_US}$pc${UI_RS}"; pt="${T[j]}"; pc="${A[j]}"; fi
    done
    [ -n "$pt" ] && out+="$pt${UI_US}$pc${UI_RS}"
    UI_P="$out"
}
# ui_sh_scale <W> <верх> <шаг> <1 — левая> → UI_P: подписи шкалы (текст).
ui_sh_scale() {
    local W="$1" mx="$2" st="$3" left="$4" g j i s
    local -a A=()
    for ((i = 0; i < W; i++)); do A[i]=' '; done
    _put() {  # _put <текст> <конец>
        local t="$1" e="$2" n="${#1}" b k
        if [ "$left" = 1 ]; then b=$(( e - n + 1 )); else b=$e; fi
        [ "$b" -gt $(( W - n )) ] && b=$(( W - n )); [ "$b" -lt 0 ] && b=0
        [ $(( b + n )) -le "$W" ] || return 0
        for ((k = b - 1; k <= b + n; k++)); do [ "$k" -ge 0 ] && [ "$k" -lt "$W" ] && [ "${A[k]}" != ' ' ] && return 0; done
        for ((k = 0; k < n; k++)); do A[b + k]="${t:k:1}"; done
    }
    if [ "$left" = 1 ]; then _put 0 $(( W - 1 )); else _put 0 0; fi
    for ((g = st; g <= mx; g += st)); do
        j=$(( (2 * g * W + mx) / (2 * mx) - 1 )); [ "$j" -lt 0 ] && j=0
        [ "$left" = 1 ] && j=$(( W - 1 - j ))
        ui_nf "$g"; _put "$UI_P" "$j"
    done
    s=""; for ((i = 0; i < W; i++)); do s+="${A[i]}"; done
    UI_P="$s"
}
# ui_sh_pyramid <L> <AX> <R> <подпись оси> <выбранный ряд> → UI_SHPY: строки
# графика по рядам SR_L (подписи), SR_I (вход), SR_O (выход).
ui_sh_pyramid() {
    local L="$1" AX="$2" R="$3" axis="$4" sel="$5" i n="${#SR_L[@]}" mi=0 mo=0 si ss so os l
    UI_SHPY=()
    for ((i = 0; i < n; i++)); do
        [ "${SR_I[i]}" -gt "$mi" ] && mi="${SR_I[i]}"; [ "${SR_O[i]}" -gt "$mo" ] && mo="${SR_O[i]}"
    done
    ui_sh_nice "$mi"; si=$NM_MAX; ss=$NM_ST
    ui_sh_nice "$mo"; so=$NM_MAX; os=$NM_ST
    ut "ВХОД" "IN"; ui_padl "← $UI_TX" "$L"; l="in${UI_US}$UI_P${UI_RS}rule${UI_US}│${UI_RS}"
    ui_padc "$axis" "$AX"; l+="muted${UI_US}$UI_P${UI_RS}rule${UI_US}│${UI_RS}"
    ut "ВЫХОД" "OUT"; ui_padr "$UI_TX →" "$R"; l+="out${UI_US}$UI_P${UI_RS}"; UI_SHPY+=("$l")
    ut "сканеры" "scanners"; ui_padl "$UI_TX" "$L"; l="muted${UI_US}$UI_P${UI_RS}rule${UI_US}│${UI_RS}"
    ui_rep ' ' "$AX"; l+="text${UI_US}$UI_P${UI_RS}rule${UI_US}│${UI_RS}"
    ut "утечка IP" "IP leak"; ui_padr "$UI_TX" "$R"; l+="muted${UI_US}$UI_P${UI_RS}"; UI_SHPY+=("$l")
    for ((i = 0; i < n; i++)); do
        ui_sh_side "${SR_I[i]}" "$L" "$si" "$ss" 1; l="$UI_P""rule${UI_US}│${UI_RS}"
        ui_padc "${SR_L[i]}" "$AX"
        if [ "$i" = "$sel" ]; then l+="title${UI_US}$UI_P${UI_RS}"; else l+="text${UI_US}$UI_P${UI_RS}"; fi
        l+="rule${UI_US}│${UI_RS}"
        ui_sh_side "${SR_O[i]}" "$R" "$so" "$os" 0; l+="$UI_P"
        if [ "$i" = "$sel" ]; then ui_sel "$l"; l="$UI_P"; fi
        UI_SHPY+=("$l")
    done
    ui_sh_scale "$L" "$si" "$ss" 1; l="muted${UI_US}$UI_P${UI_RS}rule${UI_US}┴${UI_RS}"
    ut "шкала" "scale"; ui_padc "$UI_TX" "$AX"; l+="muted${UI_US}$UI_P${UI_RS}rule${UI_US}┴${UI_RS}"
    ui_sh_scale "$R" "$so" "$os" 0; l+="muted${UI_US}$UI_P${UI_RS}"; UI_SHPY+=("$l")
}
# ui_sh_info <подпись> <вход> <выход> → UI_P: «▸ вт 03.11: вход 1 870 · выход 17».
ui_sh_info() {
    UI_SEG=""; _s cursor "▸ "; _s text "$1: "
    ui_nf "$2"; ut "вход " "in "; _s in "$UI_TX$UI_P"; _s muted " · "
    ui_nf "$3"; ut "выход " "out "; _s out "$UI_TX$UI_P"; UI_P="$UI_SEG"
}
# ui_sh_series <вид 0–3> <C> → SR_L, SR_I, SR_O, SR_AX: ряды графика вида.
ui_sh_series() {
    local v="$1" C="$2" i j k a b hh
    SR_L=(); SR_I=(); SR_O=()
    case "$v" in
        0) for ((i = 0; i + 1 < ${#SM_HH[@]}; i += 2)); do
               printf -v hh '%02d' $(( (10#${SM_HH[i]} + 2) % 24 ))
               SR_L+=("${SM_HH[i]}–$hh"); SR_I+=($(( SM_HI[i] + SM_HI[i + 1] ))); SR_O+=($(( SM_HO[i] + SM_HO[i + 1] )))
           done
           ut "часы" "hours" ;;
        1) for ((i = 23; i < ${#SM_DD[@]}; i++)); do ui_sh_dlab "$i" "$C"; SR_L+=("$UI_P"); SR_I+=("${SM_DI[i]}"); SR_O+=("${SM_DO[i]}"); done
           ut "день" "day" ;;
        2) k=3; [ "$C" -ge 80 ] && k=2
           for ((i = 0; i < ${#SM_DD[@]}; i += k)); do
               a=0; b=0
               for ((j = i; j < i + k && j < ${#SM_DD[@]}; j++)); do a=$(( a + SM_DI[j] )); b=$(( b + SM_DO[j] )); done
               if [ "${LANG_CODE:-ru}" = en ]; then ui_sh_mon $(( 10#${SM_DM[i]} )); SR_L+=("$(( 10#${SM_DD[i]} )) $UI_P")
               else SR_L+=("${SM_DD[i]}.${SM_DM[i]}"); fi
               SR_I+=("$a"); SR_O+=("$b")
           done
           if [ "$C" -ge 80 ]; then ut "2 дня" "2 days"; else ut "3 дня" "3 days"; fi ;;
        *) for ((i = 0; i < ${#SM_MM[@]}; i++)); do
               ui_sh_mon "${SM_MM[i]}"; printf -v hh '%02d' $(( 10#${SM_MY[i]} % 100 ))
               SR_L+=("$UI_P $hh"); SR_I+=("${SM_MI[i]}"); SR_O+=("${SM_MO[i]}")
           done
           ut "месяц" "month" ;;
    esac
    SR_AX="$UI_TX"
}
# Подпись пика вида → UI_P.
ui_sh_peaklab() {  # ui_sh_peaklab <вид>
    local v="$1" a="${SM_PKA[$1]}" x y z
    case "$v" in
        0) [ -n "$a" ] || { UI_P="—"; return 0; }
           printf -v x '%02d' $(( (10#$a + 1) % 24 )); UI_P="$a:00–$x:00" ;;
        1|2) [ -n "$a" ] || { UI_P="—"; return 0; }
           IFS='|' read -r x y z <<<"$a"; ui_sh_dlab3 "$x" "$y" "$z" 80 ;;
        *) [ -n "$a" ] || { UI_P="—"; return 0; }
           IFS='|' read -r x y <<<"$a"; ui_sh_mon "$x"; UI_P="$UI_P $y" ;;
    esac
}
# Пик вида → UI_P: «метка · число»; попыток не было — «—», а не первый
# час (день, месяц) окна с 0 (К5-7, стенд 03.11).
ui_sh_peak() {  # ui_sh_peak <вид>
    local a
    if [ "${SM_PKV[$1]:-0}" = 0 ]; then UI_P="—"; return 0; fi
    ui_sh_peaklab "$1"; a="$UI_P"; ui_nf "${SM_PKV[$1]}"; UI_P="$a · $UI_P"
}
# Спарклайн за 7 дней (▁…█) → UI_P.
ui_sh_spark() {  # ui_sh_spark <in|out>
    local i v mn=-1 mx=0 d s=""
    local -a SPK=(' ' '▁' '▂' '▃' '▃' '▅' '▅' '▇' '█') V=()
    for ((i = 23; i < 30; i++)); do if [ "$1" = out ]; then V+=("${SM_DO[i]}"); else V+=("${SM_DI[i]}"); fi; done
    for v in "${V[@]}"; do { [ "$mn" -lt 0 ] || [ "$v" -lt "$mn" ]; } && mn=$v; [ "$v" -gt "$mx" ] && mx=$v; done
    d=$(( mx - mn )); [ "$d" -lt 1 ] && d=1
    for v in "${V[@]}"; do s+="${SPK[$(( 1 + ((v - mn) * 14 + d) / (2 * d) ))]}"; done
    UI_P="$s"
}
# Строка «вход ▃▂▅▁▅█▇ ✓  выход ▃▁█▂▅▅▇ ✓» под списком главного меню → UI_P.
ui_sh_lineA() {
    local gi=ok gs="✓"
    [ "${SHS_SCAN:-0}" = 1 ] || { gi=warn; gs="!"; }
    UI_SEG=""
    ut "вход " "in "; _s in "$UI_TX"; ui_sh_spark in; _s in "$UI_P"; _s text " "; _s "$gi" "$gs"; _s text "  "
    ut "выход " "out "; _s out "$UI_TX"
    if [ "${SHS_VK:-0}" = 1 ]; then ui_sh_spark out; _s out "$UI_P"; _s text " "; _s ok "✓"
    else ut "! выкл" "! off"; _s warn "$UI_TX"; fi
    UI_P="$UI_SEG"
}
# Три строки счётчиков за сутки (g1, курсор на s) → UI_SHCN.
ui_sh_counters() {
    local on="${SHS_SCAN:-0}" a b
    UI_SHCN=()
    ui_nf "${SM_IN[0]}"; a="$UI_P"
    if [ "${SM_LV:-0}" -le 1 ] 2>/dev/null; then b="—"; else ui_nf "${SM_AD[0]}"; b="$UI_P"; fi
    UI_SEG=""; _s text "  "
    if [ "$on" = 1 ]; then _s ok "✓"; ut " Вход · сканеры остановлены: " " In · scanners stopped: "; _s text "$UI_TX"; _s title "$a · $b"
    else _s warn "!"; ut " Вход · выкл · только считает: " " In · off · counting only: "; _s text "$UI_TX"; _s warn "$a · $b"; fi
    UI_SHCN+=("$UI_SEG")
    UI_SEG=""; _s text "  "
    if [ "${SHS_VK:-0}" = 1 ]; then ui_nf "${SM_OUT[0]}"; _s ok "✓"; ut " Выход · утечка IP предотвращена: " " Out · IP leak prevented: "; _s text "$UI_TX"; _s title "$UI_P"
    else _s warn "!"; ut " Выход: защита от утечки IP не работает" " Out: IP leak protection is not working"; _s warn "$UI_TX"; fi
    UI_SHCN+=("$UI_SEG")
    ut "  за сутки: попыток · адресов · соединений" "  24 h: attempts · addresses · connections"; UI_SHCN+=("muted${UI_US}$UI_TX${UI_RS}")
}
# Число или «—» (данных нет) с прижатием вправо → UI_P. Точно, если влезает в ширину,
# иначе коротко (ui_nfs); не обрезается: длинное выходит за поле, а не теряет цифры.
_sh_num() {  # _sh_num <есть 0|1> <число> <ширина>
    if [ "$1" = 1 ]; then ui_nf "$2"; [ "${#UI_P}" -gt "$3" ] && ui_nfs "$2"; ui_padn "$UI_P" "$3"; else ui_padl "—" "$3"; fi
}
# Порт и число (ПОРТЫ на sh-e) → UI_P: порт слева в pw клеток, число — по _sh_num в nw,
# прижато вправо в ширину столбца cw (_sh_pnw); между портом и числом всегда хоть один
# пробел («2443/tcp 12 872», в макете слитно).
_sh_pn() {  # _sh_pn <порт> <число> <pw> <nw> <cw>
    local p="$1"
    _sh_num 1 "$2" "$4"; ui_padn "$UI_P" "$5"
    if [ "${#p}" -ge "$3" ] && [ "${UI_P:0:1}" != " " ]; then UI_P="$p $UI_P"
    else local n="$UI_P"; ui_padr "$p" "$3"; UI_P="$UI_P$n"; fi
}
# Число выбранной строки графика (80 колонок): поле 8, но точно до 9 знаков
# («1 234 567» — место справа есть), длиннее — коротко → UI_P.
_sh_nrow() { ui_nf "$1"; [ "${#UI_P}" -gt 9 ] && ui_nfs "$1"; ui_padn "$UI_P" 8; }
# Ширина столбца чисел ПОРТОВ периода v: самое длинное из _sh_num, не меньше nw → UI_P.
_sh_pnw() {  # _sh_pnw <v> <nw>
    local j w="$2"
    for ((j = $1 * 4; j < $1 * 4 + SM_PN[$1]; j++)); do _sh_num 1 "${SM_PV[j]}" "$2"; [ "${#UI_P}" -gt "$w" ] && w=${#UI_P}; done
    UI_P=$w
}
# Карточка «Защиты» (card макета) для главного меню и меню «Защита» →
# UI_SCL (15 строк без отступа), UI_SCT, UI_SCRT (правый край заголовка; не UI_SCR — это экран).
ui_sh_card() {  # ui_sh_card <выбранный день 0–6>
    local sel="$1" i l a ok=0 ad=0 on="${SHS_SCAN:-0}" vk="${SHS_VK:-0}"
    [ "$sel" -lt 0 ] && sel=0; [ "$sel" -gt 6 ] && sel=6
    [ "${SM_OK:-0}" = 1 ] && ok=1
    [ "$ok" = 1 ] && [ "${SM_LV:-0}" -ge 2 ] 2>/dev/null && ad=1
    UI_SCL=()
    ui_sh_alarms 37
    if [ "${#UI_SHA[@]}" -gt 0 ]; then
        for ((i = 0; i < ${#UI_SHA[@]} && i < 10; i++)); do UI_SCL+=("${UI_SHA[i]}"); done
    elif [ "$ok" = 0 ]; then
        ui_sh_nodata; ui_wrap "$UI_TX" 37
        for l in "${UI_WRAP[@]}"; do UI_SCL+=("muted${UI_US}$l${UI_RS}"); done
    else
        SR_L=(); SR_I=(); SR_O=()
        for ((i = 23; i < 30; i++)); do ui_sh_dlab "$i" 46; SR_L+=("$UI_P"); SR_I+=("${SM_DI[i]}"); SR_O+=("${SM_DO[i]}"); done
        ut "день" "day"; ui_sh_pyramid 15 6 15 "$UI_TX" "$sel"
        UI_SCL+=("${UI_SHPY[@]}")
    fi
    while [ "${#UI_SCL[@]}" -lt 10 ]; do UI_SCL+=(""); done
    ut "СУТКИ" "24 H"; ui_padl "$UI_TX" 9; a="$UI_P"; ut "7 ДНЕЙ" "7 DAYS"; ui_padl "$UI_TX" 10
    printf -v l '%16s%s%s' '' "$a" "$UI_P"; UI_SCL+=("muted${UI_US}$l${UI_RS}")
    UI_SEG=""
    if [ "$on" = 1 ]; then _s ok "✓ "; ut "вход, попыток" "in, attempts"; else _s warn "! "; ut "вход выкл, счёт" "in off, counted"; fi
    ui_padr "$UI_TX" 14; _s text "$UI_P"
    _sh_num "$ok" "${SM_IN[0]:-0}" 9; a="$UI_P"; _sh_num "$ok" "${SM_IN[1]:-0}" 10; _s text "$a$UI_P"
    UI_SCL+=("$UI_SEG")
    UI_SEG=""; ut "  адресов" "  addresses"; ui_padr "$UI_TX" 16; _s muted "$UI_P"
    _sh_num "$ad" "${SM_AD[0]:-0}" 9; a="$UI_P"; _sh_num "$ad" "${SM_AD[1]:-0}" 10; _s text "$a$UI_P"
    UI_SCL+=("$UI_SEG")
    UI_SEG=""
    if [ "$vk" = 1 ]; then
        _s ok "✓ "; ut "выход, к ВК" "out, to VK"; ui_padr "$UI_TX" 14; _s text "$UI_P"
        _sh_num "$ok" "${SM_OUT[0]:-0}" 9; a="$UI_P"; _sh_num "$ok" "${SM_OUT[1]:-0}" 10; _s text "$a$UI_P"
    else _s warn "! "; ut "выход выкл: утечка IP не защищена" "out off: IP leak not protected"; _s warn "$UI_TX"; fi
    UI_SCL+=("$UI_SEG")
    if ui_sh_cardok; then i=$(( 23 + sel )); ui_sh_dlab "$i" 80; ui_sh_info "$UI_P" "${SM_DI[i]}" "${SM_DO[i]}"; UI_SCL+=("$UI_P")
    else UI_SCL+=(""); fi
    ut "Защита от сканеров" "Scanner protection"; UI_SCT="title${UI_US}$UI_TX${UI_RS}"
    if [ "${SHS_ST:-}" = bad ]; then ut "не работает" "not working"; UI_SCRT="err${UI_US}✗ ${UI_RS}err${UI_US}$UI_TX${UI_RS}"
    elif [ "$on" = 1 ] && [ "$vk" = 1 ]; then ut "вкл" "on"; UI_SCRT="ok${UI_US}✓ ${UI_RS}ok${UI_US}$UI_TX${UI_RS}"
    elif [ "$on" != 1 ]; then ut "вход выкл" "in off"; UI_SCRT="warn${UI_US}! ${UI_RS}warn${UI_US}$UI_TX${UI_RS}"
    else ut "выход выкл" "out off"; UI_SCRT="warn${UI_US}! ${UI_RS}warn${UI_US}$UI_TX${UI_RS}"; fi
}

# Пункты меню «Защита» — одни на «Аркаду» и нумерованное меню (MENU_ITEMS
# строятся из них же) → SHI_KEY, SHI_LABEL, SHI_ACT, SHI_TAG, SHI_TAGT, SHI_HINT.
shield_items() {
    local a b d
    SHI_KEY=(); SHI_LABEL=(); SHI_ACT=(); SHI_TAG=(); SHI_TAGT=(); SHI_HINT=()
    _shi() { SHI_KEY+=("$1"); SHI_LABEL+=("$2"); SHI_ACT+=("$3"); SHI_TAG+=("$4"); SHI_TAGT+=("$5"); SHI_HINT+=("$6"); }
    if [ "${SHS_SCAN:-0}" = 1 ]; then
        ut "Выключить защиту" "Turn protection off"; a="$UI_TX"; ut "Сервер перестанет блокировать вход." "The server stops blocking inbound."; b="$UI_TX"
        ut "✓ вкл" "✓ on"; _shi 1 "$a" sh:scan "$UI_TX" ok "$b"
    else
        ut "Включить защиту" "Turn protection on"; a="$UI_TX"; ut "Сервер начнёт блокировать вход." "The server starts blocking inbound."; b="$UI_TX"
        ut "! выкл" "! off"; _shi 1 "$a" sh:scan "$UI_TX" warn "$b"
    fi
    ut "ВК: не выпускать" "VK: block outbound"; a="$UI_TX"; ut "Защита от утечки IP к сетям ВК." "IP leak protection towards VK."; b="$UI_TX"
    if [ "${SHS_VK:-0}" = 1 ]; then ut "✓ вкл" "✓ on"; _shi 2 "$a" sh:vk "$UI_TX" ok "$b"; else ut "! выкл" "! off"; _shi 2 "$a" sh:vk "$UI_TX" warn "$b"; fi
    d=""
    if [[ "${SHS_DATE:-}" =~ ^([0-9]{2})\.([0-9]{2})$ ]]; then
        if [ "${LANG_CODE:-ru}" = en ]; then ui_sh_mon $(( 10#${BASH_REMATCH[2]} )); d="$(( 10#${BASH_REMATCH[1]} )) $UI_P"
        else d="от ${SHS_DATE}"; fi
    fi
    ut "Обновить списки" "Update lists"; a="$UI_TX"; ut "Скачать свежие AS_Network_List." "Fetch fresh AS_Network_List."; _shi 3 "$a" sh:update "$d" muted "$UI_TX"
    ui_nf "${SHS_NEX:-0}"; d="$UI_P"
    ut "Исключения" "Exclusions"; a="$UI_TX"; ut "Сети, которые защита пропускает." "Networks the protection lets through."; _shi 4 "$a" sh:exclude "$d" muted "$UI_TX"
    ut "Свои добавки" "Own additions"; a="$UI_TX"; ut "Свои сети в дополнение к спискам." "Your own networks on top of the lists."; _shi 5 "$a" sh:block "" "" "$UI_TX"
    ut "Статистика" "Statistics"; a="$UI_TX"; ut "Графики входа и выхода за 4 периода." "In and out charts for 4 periods."; _shi 6 "$a" sh:stats "" "" "$UI_TX"
    ut "Топ-30 сканеров" "Top 30 scanners"; a="$UI_TX"; ut "Сети, которые стучались чаще всего." "Networks that knocked most often."; _shi 7 "$a" sh:top "" "" "$UI_TX"
    ut "Настройки статистики" "Statistics settings"; a="$UI_TX"; ut "Размер на диске, обнуление." "Size on disk, reset."; _shi 8 "$a" sh:set "" "" "$UI_TX"
    ut "Удалить защиту" "Remove protection"; a="$UI_TX"; ut "Спросит 1 Да / 2 Нет." "Asks 1 Yes / 2 No."; _shi 9 "$a" sh:remove "" "" "$UI_TX"
    ut "Назад" "Back"; a="$UI_TX"; ut "В главное меню goInstaller." "Back to the goInstaller main menu."; _shi 0 "$a" back "" "" "$UI_TX"
}

# ── общие строки экранов статистики ──
# Благодарность автору списков (footer макета) — в конец тела.
ui_sh_footer() {
    local l p link="github.com/C24Be/AS_Network_List" a b
    ut "Списки сетей — открытый проект AS_Network_List · $link (BSD-2)" "Network lists: open project AS_Network_List · $link (BSD-2)"; a="$UI_TX"
    ut "Спасибо автору C24Be за данные и идею. Защита в goInstaller — anten-ka." "Thanks to C24Be for the data and the idea. goInstaller protection — anten-ka."; b="$UI_TX"
    for p in "$a" "$b"; do
        ui_wrapk "$p" $(( UI_C - 2 )) "$link"
        for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  $l${UI_RS}"; done
    done
}
# Тело — ровно n строк (лишнее отрезать, недостающее добить пустыми).
ui_sh_bodyto() { while [ "${#UI_BODY[@]}" -lt "$1" ]; do UI_BODY+=(""); done; UI_BODY=("${UI_BODY[@]:0:$1}"); }
# «✓ вход вкл · ✓ выход вкл » справа в заголовке → UI_P.
ui_sh_status() {
    local a=ok b=ok ga="✓" gb="✓"
    [ "${SHS_SCAN:-0}" = 1 ] || { a=warn; ga="!"; }
    [ "${SHS_VK:-0}" = 1 ] || { b=warn; gb="!"; }
    UI_SEG=""; _s "$a" "$ga "
    if [ "$a" = ok ]; then ut "вход вкл" "in on"; else ut "вход выкл" "in off"; fi; _s "$a" "$UI_TX"
    _s muted " · "; _s "$b" "$gb "
    if [ "$b" = ok ]; then ut "выход вкл" "out on"; else ut "выход выкл" "out off"; fi; _s "$b" "$UI_TX"
    _s text " "; UI_P="$UI_SEG"
}
ui_sh_titlerow() {  # ui_sh_titlerow <заголовок> [правые сегменты]
    ui_spread "title${UI_US}  $1${UI_RS}" "${2:-}" "$UI_C"; ui_body "$UI_P"
}
ui_sh_tabbar() {  # ui_sh_tabbar <выбранный период>
    local cur="$1" i
    local -a L=()
    if [ "$UI_C" -ge 80 ]; then ut "24 часа|7 дней|месяц|всё время" "24 hours|7 days|month|all time"
    else ut "24 ч|7 дн|месяц|всё" "24 h|7 d|month|all"; fi
    IFS='|' read -r -a L <<<"$UI_TX"
    UI_SEG=""; _s text "  "
    for ((i = 0; i < 4; i++)); do
        _s grad "═ "; _s key "$(( i + 1 ))"
        if [ "$i" = "$cur" ]; then _s cursor " ● "; _s title "${L[i]}"; else _s muted " ○ "; _s text "${L[i]}"; fi
        _s text " "
    done
    ui_len "$UI_SEG"; [ "$UI_N" -lt $(( UI_C - 1 )) ] && { ui_rep '═' $(( UI_C - 1 - UI_N )); _s grad "$UI_P"; }
    ui_body "$UI_SEG"
}
# Пункт меню «Защита»: « ▸ 1 Подпись…  ✓ вкл» → UI_P.
ui_sh_itemrow() {  # ui_sh_itemrow <номер> <выбран> <ширина подписи>
    local i="$1"
    UI_SEG=""; _s text " "
    if [ "$2" = 1 ]; then _s cursor "▸ "; _s cursor "${IT_KEY[i]} "; else _s cursor "  "; _s muted "${IT_KEY[i]} "; fi
    ui_padr "${IT_LABEL[i]}" "$3"; if [ "$2" = 1 ]; then _s title "$UI_P"; else _s "${IT_TOK[i]:-name}" "$UI_P"; fi
    [ -n "${IT_TAG[i]}" ] && _s "${IT_TAGT[i]}" "${IT_TAG[i]}"
    UI_P="$UI_SEG"
}

# ── sh-d: меню «Защита» ──
# Защиты нет — прежний экран: что делает и «1 Включить защиту».
ui_scr_shield_none() {
    local l a
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ut "Защита от сканеров" "Scanner protection"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "AS_Network_List"; ui_body ""
    ui_items_clear
    ut "Новые соединения из сетей госорганов и ВК, которые сканируют серверы, отбрасываются: сканер не увидит портов. Ещё закрывает сети ВК для клиентов VPN и самого сервера. Списки — открытый проект AS_Network_List, обновляются каждый день. SSH открыт всегда." "New connections from government and VK networks that scan servers are dropped: a scanner will not see the ports. It also closes VK networks to VPN clients and the server itself. The lists come from the open AS_Network_List project and update daily. SSH always stays open."
    ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  ${l}${UI_RS}"; done
    if [ -n "${SHS_UNSUP:-}" ]; then
        ut "Раньше не поставилась:" "Earlier it did not install:"; ui_wrap "$UI_TX ${SHS_UNSUP}" $(( UI_C - 4 ))
        for l in "${UI_WRAP[@]}"; do ui_body "err${UI_US}  ${l}${UI_RS}"; done
    fi
    ui_body ""
    ut "Включить защиту" "Turn protection on"; a="$UI_TX"; ut "скачать списки и применить" "download the lists and apply"; ui_item 1 "$a" sh:on "$UI_TX"
    ui_item_back
    [ "$UI_CUR" -lt "${#IT_KEY[@]}" ] || UI_CUR=0
    ui_choicerows "$UI_CUR"
    ui_keys_nav
}
ui_scr_shield() {  # ui_scr_shield <cur>
    local i n sel l p lf rf LW=37 RW H=16 a b
    UI_CUR="$1"
    ui_sh_inst || { ui_scr_shield_none; return 0; }
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_items_clear; shield_items
    for ((i = 0; i < ${#SHI_KEY[@]}; i++)); do ui_item "${SHI_KEY[i]}" "${SHI_LABEL[i]}" "${SHI_ACT[i]}" "${SHI_HINT[i]}" muted "${SHI_TAG[i]}" "${SHI_TAGT[i]}"; done
    n=${#IT_KEY[@]}; [ "$UI_CUR" -lt "$n" ] || UI_CUR=0
    ui_hud
    ui_sh_card "${UI_SHROW:-6}"
    if [ "$UI_C" -ge 80 ]; then
        RW=$(( UI_C - LW - 2 ))
        ui_lclear
        for ((i = 0; i < n; i++)); do
            sel=0; [ "$i" = "$UI_CUR" ] && sel=1
            [ "${IT_KEY[i]}" = 0 ] && { ui_rep '─' $(( LW - 4 )); ui_lpush "rule${UI_US} $UI_P${UI_RS}" 0; }
            ui_sh_itemrow "$i" "$sel" 21; ui_lpush "$UI_P" "$sel"
        done
        while [ "${#UI_LS[@]}" -lt $(( H - 1 )) ]; do ui_lpush "" 0; done
        ui_lpush "text${UI_US} ${UI_RS}key${UI_US}goinstall --shield stats${UI_RS}" 0
        ut "ДЕЙСТВИЯ" "ACTIONS"; ui_frame2 "$LW" "$H" "title${UI_US}$UI_TX${UI_RS}" ""; lf=("${UI_FR[@]}")
        ui_lclear
        for ((i = 0; i < H - 1; i++)); do ui_lpush "text${UI_US} ${UI_RS}${UI_SCL[i]:-}" 0; done
        ui_lpush "text${UI_US} ${UI_RS}muted${UI_US}${IT_NOTE[UI_CUR]}${UI_RS}" 0
        ui_frame2 "$RW" "$H" "$UI_SCT" "$UI_SCRT"; rf=("${UI_FR[@]}")
        for ((i = 0; i < H + 2; i++)); do
            if [ "$i" = 0 ]; then p=" "; else p="░"; fi
            ui_body "${lf[$i]}shadow${UI_US}$p${UI_RS}${rf[$i]}shadow${UI_US}$p${UI_RS}"
        done
        ui_rep '░' "$LW"; a="$UI_P"; ui_rep '░' "$RW"
        ui_body "text${UI_US} ${UI_RS}shadow${UI_US}$a${UI_RS}text${UI_US} ${UI_RS}shadow${UI_US}$UI_P${UI_RS}"
        ui_sh_footer
        ut "сразу" "jump"; a="$UI_TX"; ut "назад" "back"; b="$UI_TX"; ut "выход" "quit"
        ui_keys_fit "↑↓|||" "Enter|||" "1–9|$a||" "0|$b||" "q|$UI_TX||"
    else
        ui_lclear
        _P1() { ui_lpush "text${UI_US} ${UI_RS}$1" 0; }
        ui_sh_alarms 41
        if [ "${#UI_SHA[@]}" -gt 0 ]; then
            for ((i = 0; i < 3; i++)); do
                l="${UI_SHA[i]:-}"
                if [ "$i" = 2 ] && [ "${#UI_SHA[@]}" -gt 3 ]; then ui_len "$l"; [ "$UI_N" -ge 41 ] || l+="text${UI_US} …${UI_RS}"; ui_fit "$l" 41; l="$UI_FIT"
                    [ "$UI_FITN" -ge 41 ] && { l="${l%"${UI_RS}"}"; l="${l%?}…${UI_RS}"; }; fi
                _P1 "$l"
            done
        else
            local okd=0 g=ok gs="✓"
            [ "${SM_OK:-0}" = 1 ] && okd=1
            [ "${SHS_SCAN:-0}" = 1 ] || { g=warn; gs="!"; }
            if [ "$okd" = 1 ]; then ui_nf "${SM_IN[0]}"; a="$UI_P"; if [ "${SM_LV:-0}" -le 1 ] 2>/dev/null; then b="—"; else ui_nf "${SM_AD[0]}"; b="$UI_P"; fi
            else a="—"; b="—"; fi
            UI_SEG=""; _s "$g" "$gs "; ut "Вход · сканеры остановлены: " "In · scanners stopped: "; _s text "$UI_TX"; _s title "$a · $b"; _P1 "$UI_SEG"
            UI_SEG=""
            if [ "${SHS_VK:-0}" = 1 ]; then
                if [ "$okd" = 1 ]; then ui_nf "${SM_OUT[0]}"; else UI_P="—"; fi
                a="$UI_P"; _s ok "✓ "; ut "Выход · утечка IP предотвращена: " "Out · IP leak prevented: "; _s text "$UI_TX"; _s title "$a"
            else _s warn "! "; ut "Выход: защита от утечки IP не работает" "Out: IP leak protection is not working"; _s warn "$UI_TX"; fi
            _P1 "$UI_SEG"
            if [ "$okd" = 1 ]; then ut "  за сутки · графики — 6 Статистика" "  over 24 h · charts — 6 Statistics"
            elif [ "${SM_LV:-}" = 0 ]; then ut "  статистики не будет: nft не умеет" "  no statistics: nft cannot count"
            else ut "  статистики ещё нет: раз в час" "  no statistics yet: once an hour"; fi
            _P1 "muted${UI_US}$UI_TX${UI_RS}"
        fi
        ui_rep '─' 41; _P1 "rule${UI_US}$UI_P${UI_RS}"
        for ((i = 0; i < n; i++)); do
            sel=0; [ "$i" = "$UI_CUR" ] && sel=1
            ui_sh_itemrow "$i" "$sel" 29; ui_lpush "$UI_P" "$sel"
        done
        ui_frame2 45 14 "$UI_SCT" "$UI_SCRT"
        for ((i = 0; i < 16; i++)); do
            if [ "$i" = 0 ]; then ui_rep ' ' $(( UI_C - 45 )); ui_body "${UI_FR[$i]}text${UI_US}$UI_P${UI_RS}"
            else ui_body "${UI_FR[$i]}shadow${UI_US}░${UI_RS}"; fi
        done
        ui_rep '░' 45; ui_body "text${UI_US} ${UI_RS}shadow${UI_US}$UI_P${UI_RS}"
        ui_sh_footer
        ut "назад" "back"; ui_keys_fit "↑↓|||" "Enter|||" "1–9|||" "0|$UI_TX||"
    fi
}

# ── sh-e: статистика ──
# Справа от графика (extras макета) → EX (строки, не шире w).
ui_sh_extras() {  # ui_sh_extras <вид> <w>
    local v="$1" w="$2" j l a
    EX=()
    _ex() { ui_fit "$1" "$w"; EX+=("$UI_FIT"); }
    ut "ПИК" "PEAK"; _ex "muted${UI_US}$UI_TX${UI_RS}"
    ui_sh_peak "$v"; _ex "text${UI_US}$UI_P${UI_RS}"
    if [ "$v" != 3 ]; then
        if [ "${SM_PKX[v]}" -lt 0 ]; then ut "всплеска нет" "no spike"; _ex "muted${UI_US}· ${UI_RS}muted${UI_US}$UI_TX${UI_RS}"
        else
            ui_dec "${SM_PKX[v]}"; a="$UI_P"
            if [ "${SM_PKS[v]}" = 1 ]; then ut "всплеск ×$a к обычному" "spike ×$a the usual"; _ex "warn${UI_US}▲ ${UI_RS}text${UI_US}$UI_TX${UI_RS}"
            else ut "всплеска нет · пик ×$a" "no spike · peak ×$a"; _ex "muted${UI_US}· ${UI_RS}muted${UI_US}$UI_TX${UI_RS}"; fi
        fi
    fi
    EX+=("")
    ut "АДРЕСА" "ADDRESSES"; _ex "muted${UI_US}$UI_TX${UI_RS}"
    if [ "${SM_NW[v]}" != - ]; then
        ut "новые" "new"; ui_padr "$UI_TX" 10; a="$UI_P"; _sh_num "$(( SM_LV >= 2 ))" "${SM_NW[v]}" 6; _ex "text${UI_US}$a${UI_RS}text${UI_US}$UI_P${UI_RS}"
        ut "повторные" "repeat"; ui_padr "$UI_TX" 10; a="$UI_P"; _sh_num "$(( SM_LV >= 2 ))" "${SM_RP[v]}" 6; _ex "text${UI_US}$a${UI_RS}text${UI_US}$UI_P${UI_RS}"
    else
        ut "всего" "total"; ui_padr "$UI_TX" 10; a="$UI_P"; _sh_num "$(( SM_LV >= 2 ))" "${SM_AD[v]}" 6; _ex "text${UI_US}$a${UI_RS}text${UI_US}$UI_P${UI_RS}"
    fi
    EX+=("")
    ut "ПОРТЫ · чаще всего" "PORTS · most hit"; _ex "muted${UI_US}$UI_TX${UI_RS}"
    if [ "$SM_LV" -ge 3 ] && [ "${SM_PN[v]}" -gt 0 ]; then
        _sh_pnw "$v" 6; a="$UI_P"
        for ((j = v * 4; j < v * 4 + SM_PN[v]; j++)); do
            _sh_pn "${SM_PP[j]}" "${SM_PV[j]}" 8 6 "$a"
            l="${SM_PL[j]}"; [ -n "$l" ] || { ut "свободен" "free"; l="$UI_TX"; }
            _ex "text${UI_US}$UI_P${UI_RS}muted${UI_US} $l${UI_RS}"
        done
    else ut "нет данных" "no data"; _ex "muted${UI_US}$UI_TX${UI_RS}"; fi
}
ui_scr_shstats() {
    local v="${UI_SHV:-0}" n sel i l a pk
    local -a CH=() E=()
    UI_BODY=(); UI_INFO=""; UI_KEYS=""; ui_items_clear
    ut "Статистика защиты" "Protection statistics"; a="$UI_TX"; ui_sh_status; ui_sh_titlerow "$a" "$UI_P"
    ui_sh_tabbar "$v"
    n=0; [ "${SM_OK:-0}" = 1 ] && { ui_sh_series "$v" "$UI_C"; n=${#SR_L[@]}; }
    UI_SHN=$n
    if [ "$n" = 0 ]; then
        ui_body ""; ui_sh_nodata; ui_wrap "$UI_TX" $(( UI_C - 4 ))
        for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  $l${UI_RS}"; done
        UI_SHSEL=0
        if [ "$UI_C" -ge 80 ]; then ui_sh_bodyto 20; else ui_sh_bodyto 18; fi
    else
        sel="${UI_SHR:--1}"; { [ "$sel" -lt 0 ] || [ "$sel" -ge "$n" ]; } && sel=$(( n - 1 ))
        UI_SHSEL=$sel
        if [ "$UI_C" -ge 80 ]; then
            ui_sh_pyramid 20 8 20 "$SR_AX" "$sel"; CH=("${UI_SHPY[@]}")
            ut "СТРОКА" "ROW"; E+=("muted${UI_US}$UI_TX · ↑↓${UI_RS}")
            E+=("title${UI_US}${SR_L[sel]}${UI_RS}")
            ut "вход" "in"; ui_padr "$UI_TX" 7; a="$UI_P"; _sh_nrow "${SR_I[sel]}"; ut " попыток" " attempts"
            E+=("in${UI_US}$a${UI_RS}text${UI_US}$UI_P${UI_RS}muted${UI_US}$UI_TX${UI_RS}")
            ut "выход" "out"; ui_padr "$UI_TX" 7; a="$UI_P"; _sh_nrow "${SR_O[sel]}"; ut " к ВК" " to VK"
            E+=("out${UI_US}$a${UI_RS}text${UI_US}$UI_P${UI_RS}muted${UI_US}$UI_TX${UI_RS}")
            E+=("")
            ui_sh_extras "$v" 25; E+=("${EX[@]}")
            n=${#CH[@]}; [ "${#E[@]}" -gt "$n" ] && n=${#E[@]}
            for ((i = 0; i < n; i++)); do
                ui_fit "${CH[i]:-}" 50; ui_rep ' ' $(( 50 - UI_FITN ))
                ui_body "text${UI_US}  ${UI_RS}$UI_FIT""text${UI_US}$UI_P${UI_RS}text${UI_US}   ${UI_RS}${E[i]:-}"
            done
            ui_sh_bodyto 20
        else
            ui_sh_pyramid 17 7 17 "$SR_AX" "$sel"
            for l in "${UI_SHPY[@]}"; do ui_body "text${UI_US} ${UI_RS}$l"; done
            ui_sh_info "${SR_L[sel]}" "${SR_I[sel]}" "${SR_O[sel]}"; ui_body "text${UI_US} ${UI_RS}$UI_P"
            ui_sh_peak "$v"; pk="$UI_P"; ut " пик " " peak "
            l="muted${UI_US}$UI_TX$pk${UI_RS}"
            if [ "$v" != 3 ] && [ "${SM_PKS[v]}" = 1 ] && [ "${SM_PKX[v]}" -ge 0 ]; then ui_dec "${SM_PKX[v]}"; l+="muted${UI_US} · ${UI_RS}warn${UI_US}▲ ×$UI_P${UI_RS}"; fi
            E+=("$l")
            if [ "${SM_NW[v]}" != - ] && [ "$SM_LV" -ge 2 ]; then
                ui_nfs "${SM_NW[v]}"; a="$UI_P"; ui_nfs "${SM_RP[v]}"; ut " адреса: новые $a · повторные $UI_P" " addresses: new $a · repeat $UI_P"
                E+=("muted${UI_US}$UI_TX${UI_RS}")
            fi
            ut " ПОРТЫ" " PORTS"; E+=("muted${UI_US}$UI_TX${UI_RS}")
            if [ "$SM_LV" -ge 3 ] && [ "${SM_PN[v]}" -gt 0 ]; then
                _sh_pnw "$v" 7; a="$UI_P"
                for ((i = v * 4; i < v * 4 + SM_PN[v]; i++)); do
                    _sh_pn "${SM_PP[i]}" "${SM_PV[i]}" 9 7 "$a"
                    l="${SM_PL[i]}"; [ -n "$l" ] || { ut "свободен" "free"; l="$UI_TX"; }
                    E+=("text${UI_US} $UI_P${UI_RS}muted${UI_US} $l${UI_RS}")
                done
            else ut " нет данных" " no data"; E+=("muted${UI_US}$UI_TX${UI_RS}"); fi
            n=$(( 18 - ${#UI_BODY[@]} ))
            if [ "$n" -gt 0 ]; then
                [ "$n" -gt 1 ] && { ui_body ""; n=$(( n - 1 )); }
                for ((i = 0; i < n && i < ${#E[@]}; i++)); do ui_body "${E[i]}"; done
            fi
            ui_sh_bodyto 18
        fi
    fi
    ui_sh_footer
    if [ "$UI_C" -ge 80 ]; then
        ut "период|строка|топ-30|настройки|назад" "period|row|top 30|settings|back"
        IFS='|' read -r a l i n pk <<<"$UI_TX"
        ui_keys_fit "1–4|$a||" "↑↓|$l||" "5|$i||" "6|$n||" "0|$pk||" "q|||"
    else
        ut "топ|назад" "top|back"; IFS='|' read -r a l <<<"$UI_TX"
        ui_keys_fit "1–4|||" "↑↓|||" "5|$a||" "6|||" "0|$l||"
    fi
}

# ── sh-g: топ-30 сканеров ──
ui_scr_shtop() {
    local v="${UI_SHV:-0}" N pg cur st i j sel a b c l last port nm at ad
    UI_BODY=(); UI_INFO=""; UI_KEYS=""; ui_items_clear
    N=0; [ "${SM_OK:-0}" = 1 ] && N="${SM_TN[v]:-0}"
    if [ "$UI_C" -ge 80 ]; then pg=15; else pg=6; fi
    [ "$pg" -gt "$N" ] && pg=$N
    cur="${UI_SHT:-0}"; [ "$cur" -ge "$N" ] && cur=$(( N - 1 )); [ "$cur" -lt 0 ] && cur=0
    UI_SHT=$cur
    st=$(( cur - pg / 2 )); [ "$st" -gt $(( N - pg )) ] && st=$(( N - pg )); [ "$st" -lt 0 ] && st=0
    at=0; [ "${SM_LV:-0}" -ge 3 ] 2>/dev/null && at=1
    ad=0; [ "${SM_LV:-0}" -ge 2 ] 2>/dev/null && ad=1
    ut "Топ-30 сканеров" "Top 30 scanners"; a="$UI_TX"
    if [ "$UI_C" -ge 80 ]; then ut "предположительно, по названию сети " "presumably, by network name "; ui_sh_titlerow "$a" "muted${UI_US}$UI_TX${UI_RS}"
    else ui_sh_titlerow "$a"; fi
    ui_sh_tabbar "$v"
    _tnm() { nm="${SM_TM[j]}"; [ -n "$nm" ] || { ut "без подписи в списке" "no label in the list"; nm="$UI_TX"; }; }
    _tas() { if [ "${SM_TS[j]}" -gt 0 ]; then a="AS${SM_TS[j]}"; else a="—"; fi; }
    if [ "$UI_C" -ge 80 ]; then
        ui_padl "№" 2; l="  $UI_P "; ui_padr AS 8; l+="$UI_P"
        ut "СЕТЬ" "NETWORK"; ui_padr "$UI_TX" 24; l+="$UI_P"; ut "ПОПЫТОК" "ATTEMPTS"; ui_padl "$UI_TX" 9; l+="$UI_P"
        ut "АДРЕСОВ" "ADDRESSES"; ui_padl "$UI_TX" 10; l+="$UI_P  "; ut "ПОСЛЕДНИЙ" "LAST SEEN"; ui_padr "$UI_TX" 13; l+="$UI_P"; ut "ПОРТ" "PORT"
        ui_body "muted${UI_US}$l$UI_TX${UI_RS}"
        for ((i = st; i < st + pg; i++)); do
            j=$(( v * 30 + i )); sel=0; [ "$i" = "$cur" ] && sel=1
            UI_SEG=""
            if [ "$sel" = 1 ]; then _s cursor "▸ "; else _s cursor "  "; fi
            ui_padl "$(( i + 1 ))" 2; if [ "$sel" = 1 ]; then _s cursor "$UI_P "; else _s muted "$UI_P "; fi
            _tas; ui_padr "$a" 8; _s text "$UI_P"
            _tnm; ui_padr "$nm" 24
            if [ -z "${SM_TM[j]}" ]; then _s muted "$UI_P"; elif [ "$sel" = 1 ]; then _s title "$UI_P"; else _s name "$UI_P"; fi
            _sh_num "$at" "${SM_TA[j]}" 9; a="$UI_P"; _sh_num "$ad" "${SM_TB[j]}" 10; _s text "$a$UI_P"
            last="${SM_TL[j]:-—}"; [ -n "$last" ] || last="—"; ui_padr "$last" 13; _s muted "  $UI_P"
            port="${SM_TO[j]}"; [ -n "$port" ] || port="—"; _s text "$port"
            if [ "$sel" = 1 ]; then ui_selrow "$UI_SEG"; else ui_body "$UI_SEG"; fi
        done
        if [ "$N" -gt 0 ]; then
            ut " из $N" " of $N"; l="  $(( st + 1 ))–$(( st + pg ))$UI_TX"
            [ $(( st + pg )) -lt "$N" ] && { ut "ниже ещё " "more below: "; l+=" · ▼ $UI_TX$(( N - st - pg ))"; }
            [ "$st" -gt 0 ] && { ut "выше " "above: "; l+=" · ▲ $UI_TX$st"; }
            ui_body "muted${UI_US}$l${UI_RS}"
        else
            if [ "${SM_OK:-0}" = 1 ]; then ut "За этот период сетей нет." "No networks in this period."; else ui_sh_nodata; fi
            ui_body "muted${UI_US}  $UI_TX${UI_RS}"
        fi
        ui_sh_bodyto 20
        ui_sh_footer
        ut "период|страница|назад|выход" "period|page|back|quit"; IFS='|' read -r a b c l <<<"$UI_TX"
        ui_keys_fit "1–4|$a||" "↑↓|||" "PgUp PgDn|$b||" "0|$c||" "q|$l||"
    else
        ut "предположительно, по названию сети" "presumably, by network name"; ui_body "muted${UI_US} $UI_TX${UI_RS}"
        for ((i = st; i < st + pg; i++)); do
            j=$(( v * 30 + i )); sel=0; [ "$i" = "$cur" ] && sel=1
            UI_SEG=""
            if [ "$sel" = 1 ]; then _s cursor "▸"; else _s cursor " "; fi
            ui_padl "$(( i + 1 ))" 2; if [ "$sel" = 1 ]; then _s cursor "$UI_P "; else _s muted "$UI_P "; fi
            _tas; ui_padr "$a" 8; _s text "$UI_P"
            _tnm; if [ -z "${SM_TM[j]}" ]; then _s muted "$nm"; elif [ "$sel" = 1 ]; then _s title "$nm"; else _s name "$nm"; fi
            if [ "$sel" = 1 ]; then ui_selrow "$UI_SEG"; else ui_body "$UI_SEG"; fi
            if [ "$at" = 1 ]; then ui_nf "${SM_TA[j]}"; a="$UI_P"; else a="—"; fi
            if [ "$ad" = 1 ]; then ui_nf "${SM_TB[j]}"; b="$UI_P"; else b="—"; fi
            last="${SM_TL[j]}"
            if [ -z "$last" ]; then last="—"; elif [ "$v" = 0 ]; then last="${last:6:5}"; else last="${last:0:5}"; fi
            port="${SM_TO[j]}"; [ -n "$port" ] || port="—"
            l="muted${UI_US}    $a · $b · $last · $port${UI_RS}"
            if [ "$sel" = 1 ]; then ui_selrow "$l"; else ui_body "$l"; fi
        done
        if [ "$N" -gt 0 ]; then
            ut " из $N" " of $N"; l=" $(( st + 1 ))–$(( st + pg ))$UI_TX"
            [ $(( st + pg )) -lt "$N" ] && { ut "ещё " "more: "; l+=" · ▼ $UI_TX$(( N - st - pg ))"; }
            ui_body "muted${UI_US}$l${UI_RS}"
        else
            if [ "${SM_OK:-0}" = 1 ]; then ut "За этот период сетей нет." "No networks in this period."; else ui_sh_nodata; fi
            ui_wrap "$UI_TX" $(( UI_C - 2 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US} $l${UI_RS}"; done
        fi
        ut "попыток · адресов · последний раз · порт" "attempts · addresses · last seen · port"; ui_body "muted${UI_US} $UI_TX${UI_RS}"
        ui_sh_bodyto 18
        ui_sh_footer
        ut "назад" "back"; ui_keys_fit "1–4|||" "↑↓|||" "PgUp PgDn|||" "0|$UI_TX||"
    fi
}

# ── sh-h: настройки статистики ──
# UI_SHH: main — пункты, confirm — «Обнулить? 1 Да / 2 Нет» (Enter — Нет),
# done — обнулено.
ui_scr_shset() {
    local st="${UI_SHH:-main}" kw=22 i l a b cur x
    UI_BODY=(); UI_INFO=""; UI_KEYS=""; ui_items_clear
    [ "$UI_C" -ge 80 ] || kw=18
    ut "Настройки статистики" "Statistics settings"; a="$UI_TX"
    if [ "$UI_C" -ge 80 ]; then ut "защита от сканеров " "scanner protection "; ui_sh_titlerow "$a" "muted${UI_US}$UI_TX${UI_RS}"
    else ui_sh_titlerow "$a"; fi
    ui_rep '═' $(( UI_C - 4 )); ui_body "grad${UI_US}  $UI_P${UI_RS}"; ui_body ""
    _kv() { ui_padr "$1" "$kw"; ui_body "muted${UI_US}  $UI_P${UI_RS}text${UI_US}$2${UI_RS}"; }
    # Когда начат счёт: после обнуления — из свежей модели, иначе «с · N дней».
    x="${SM_ST:-}"; [ -n "$x" ] && [ -n "${SM_STT:-}" ] && x+=" ${SM_STT}"
    [ -n "$x" ] || x="${UI_SHRT:-—}"
    ut "собирается с" "collected since"; a="$UI_TX"
    if [ "$st" = done ] || [ -z "${SM_ST:-}" ]; then _kv "$a" "$x"
    else ui_pl "${SM_ND:-0}" "день" "дня" "дней" "day" "days"; _kv "$a" "${SM_ST} · ${SM_ND:-0} $UI_P"; fi
    i=$(( (${SM_BY:-0} * 10 + 524288) / 1048576 )); [ "${SM_BY:-0}" -gt 0 ] && [ "$i" -lt 1 ] && i=1
    ui_dec "$i"; ut "на диске" "on disk"; a="$UI_TX"; ut " МБ" " MB"; _kv "$a" "$UI_P$UI_TX"
    ui_nf "${SM_NA:-0}"; ut "адресов в памяти" "addresses in memory"; _kv "$UI_TX" "$UI_P"
    ui_body ""
    if [ "$st" = confirm ]; then
        ut "Обнулить статистику? Счётчики входа и выхода, графики и топ начнутся заново." "Reset statistics? In and out counters, charts and the top start over."
        ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "title${UI_US}  $l${UI_RS}"; done
        ut "  Списки сетей и правила защиты не изменятся. Enter — 2, Нет" "  Network lists and protection rules stay. Enter — 2, No"; ui_body "muted${UI_US}$UI_TX${UI_RS}"
        ui_body ""
        ut "Да, обнулить" "Yes, reset"; a="$UI_TX"; ut "Нет" "No"; b="$UI_TX"
        set -- 1 "$a" 2 "$b"; cur=0   # как в макете; Enter всё равно — «Нет»
    else
        if [ "$st" = done ]; then
            if [ "${LANG_CODE:-ru}" = en ] && [[ "$x" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})(.*)$ ]]; then
                x="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}${BASH_REMATCH[4]}"
            fi
            ut "Статистика обнулена. Собирается заново с $x." "Statistics reset. Collecting again since $x."
            ui_body "ok${UI_US}  ✓ ${UI_RS}text${UI_US}$UI_TX${UI_RS}"; ui_body ""
        fi
        ut "Обнулить статистику" "Reset statistics"; a="$UI_TX"; ut "Назад" "Back"; b="$UI_TX"
        set -- 1 "$a" 0 "$b"; cur="${UI_SHC:-0}"
    fi
    for i in 0 1; do
        UI_SEG=""; _s text "  "
        if [ "$i" = "$cur" ]; then _s cursor "▸ "; _s cursor "$1  "; _s title "$2"; ui_selrow "$UI_SEG"
        else _s cursor "  "; _s key "$1  "; _s name "$2"; ui_body "$UI_SEG"; fi
        shift 2
    done
    if [ "$st" = main ]; then
        ui_body ""
        ut "Обнуление стирает счётчики, графики и топ. Списки сетей и правила защиты остаются." "Reset clears counters, charts and the top. Network lists and protection rules stay."
        ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  $l${UI_RS}"; done
    fi
    ui_sh_bodyto 23
    if [ "$st" = confirm ]; then ut "да|нет" "yes|no"; IFS='|' read -r a b <<<"$UI_TX"; ui_keys_fit "1|$a||" "2|$b||" "Enter|$b||"
    else ut "назад" "back"; ui_keys_fit "↑↓|||" "Enter|||" "1|||" "0|$UI_TX||"; fi
}

# ── клавиши экранов защиты ──
# ←→ приходят как Enter/Esc (UI_ARROW — какая стрелка). На графике
# статистики и у карточки «Защиты» в главном меню они листают.
ui_sh_arrow() {
    case "$UI_SCR" in
        shstats) UI_KEY="$UI_ARROW" ;;
        menu) [ "$UI_C" -ge 80 ] && [ "${MI_KEY[$UI_CUR]:-}" = s ] && ui_sh_cardok && UI_KEY="$UI_ARROW" ;;
    esac
    return 0
}
# Клавиши, которые экраны защиты берут себе (rc 0), а не общий разбор.
ui_sh_key() {
    case "$UI_SCR:$UI_KEY" in
        shstats:[1-6]|shstats:up|shstats:down|shstats:left|shstats:right) return 0 ;;
        shtop:[1-4]|shtop:up|shtop:down|shtop:pgup|shtop:pgdn|shtop:home|shtop:end) return 0 ;;
        shset:up|shset:down|shset:enter|shset:1) return 0 ;;
        shset:2|shset:esc|shset:0) [ "${UI_SHH:-main}" = confirm ] && return 0 ;;
        menu:left|menu:right) return 0 ;;
    esac
    return 1
}
ui_sh_do() {  # ui_sh_do <клавиша>
    local k="$1" n pg
    case "$UI_SCR" in
        menu)
            n="${UI_SHROW:-6}"
            case "$k" in left) n=$(( n - 1 )) ;; right) n=$(( n + 1 )) ;; esac
            [ "$n" -lt 0 ] && n=0; [ "$n" -gt 6 ] && n=6
            UI_SHROW=$n ;;
        shstats)
            n="${UI_SHSEL:-0}"
            case "$k" in
                [1-4]) UI_SHV=$(( k - 1 )); UI_SHR=-1 ;;
                left)  [ "${UI_SHV:-0}" -gt 0 ] && { UI_SHV=$(( UI_SHV - 1 )); UI_SHR=-1; } ;;
                right) [ "${UI_SHV:-0}" -lt 3 ] && { UI_SHV=$(( ${UI_SHV:-0} + 1 )); UI_SHR=-1; } ;;
                up)    [ "$n" -gt 0 ] && UI_SHR=$(( n - 1 )) ;;
                down)  [ "$n" -lt $(( ${UI_SHN:-0} - 1 )) ] && UI_SHR=$(( n + 1 )) ;;
                5) UI_SHT=0; ui_go shtop 0 ;;
                6) UI_SHH=main; UI_SHC=0; ui_go shset 0 ;;
            esac ;;
        shtop)
            case "$k" in [1-4]) UI_SHV=$(( k - 1 )); UI_SHT=0; return 0 ;; esac
            n=0; [ "${SM_OK:-0}" = 1 ] && n="${SM_TN[${UI_SHV:-0}]:-0}"
            if [ "$UI_C" -ge 80 ]; then pg=15; else pg=6; fi
            UI_SHT="${UI_SHT:-0}"
            case "$k" in
                up) UI_SHT=$(( UI_SHT - 1 )) ;; down) UI_SHT=$(( UI_SHT + 1 )) ;;
                pgup) UI_SHT=$(( UI_SHT - pg )) ;; pgdn) UI_SHT=$(( UI_SHT + pg )) ;;
                home) UI_SHT=0 ;; end) UI_SHT=$(( n - 1 )) ;;
            esac
            [ "$UI_SHT" -ge "$n" ] && UI_SHT=$(( n - 1 )); [ "$UI_SHT" -lt 0 ] && UI_SHT=0 ;;
        shset)
            if [ "${UI_SHH:-main}" = confirm ]; then
                case "$k" in
                    # «1» в первые 0,4 с после вопроса — вторая «1» той же пары (экран
                    # не сразу отозвался), а не ответ: глотается, как Enter в ui_main.
                    1) _ui_now_ms; [ "$UI_NOW" -lt "${UI_SWALLOW_T:-0}" ] && return 0
                       ui_sh_reset ;;
                    2|enter|esc|0) UI_SHH=main; UI_SHC=0
                       ut "Не обнулено." "Not reset."; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 3 )) ;;
                esac
            else
                case "$k" in
                    up|down) UI_SHC=$(( 1 - ${UI_SHC:-0} )) ;;
                    1) UI_SHH=confirm ;;
                    enter) if [ "${UI_SHC:-0}" = 0 ]; then UI_SHH=confirm; else ui_back; fi ;;
                esac
                # Вопрос показан (и цифрой, и Enter): отсчёт глотания «1» — отсюда.
                [ "$UI_SHH" = confirm ] && { _ui_now_ms; UI_SWALLOW_T=$(( UI_NOW + 400 )); }
            fi ;;
    esac
    return 0
}
# Обнулить статистику из «Аркады»: вопрос уже задан экраном (1 Да).
# Замок защиты — без ожидания: её занимает другая операция (обновление списков,
# пересборка) — сказать сразу, а не молча ждать до 3 мин. Клавиши, нажатые, пока
# шёл сброс, выбрасываются: иначе «1» на экране «обнулено» снова открыла бы вопрос.
ui_sh_reset() {
    UI_SHC=0
    ui_osup_guard && { UI_SHH=main; return 0; }
    if ! _shield_lock 0; then
        ut "Защита занята другой операцией — повторите через минуту" "Protection is busy with another operation — try again in a minute"
        UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 6 )); UI_SHH=main; ui_flush_input; return 0
    fi
    ut "Обнуляю статистику…" "Resetting the statistics…"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 60 )); ui_draw
    if shield_stats_reset >/dev/null 2>&1; then
        UI_NOTE=""; UI_SHH=done; printf -v UI_SHRT '%(%d.%m.%Y %H:%M)T' -1
        ui_sh_model
    else
        ut "Не обнулилось: " "Did not reset: "; UI_NOTE="$UI_TX${SHIELD_ERR:-?}"; UI_NOTE_T=$(( SECONDS + 6 )); UI_SHH=main
    fi
    _shield_unlock
    ui_flush_input
    return 0
}
ui_shield_open() { shield_state --live; ui_sh_model; ui_go shield 0; }
# Карточка пункта s в главном меню, пока защиты нет → UI_SCL.
ui_shield_cardlines() {
    UI_SCL=()
    ut "SSH открыт всегда" "SSH always stays open"; UI_SCL+=("muted${UI_US}$UI_TX${UI_RS}")
    ut "списки AS_Network_List, каждый день" "AS_Network_List lists, daily"; UI_SCL+=("muted${UI_US}$UI_TX${UI_RS}")
}
# Действие пункта — в обычном терминале (вопросы, ввод адреса, ход
# скачивания), потом назад на экран со свежим состоянием.
ui_shield_run() {  # ui_shield_run <функция> [аргументы]
    local st
    ui_osup_guard && return 0
    ui_comp_refresh_stop
    ui_leave_screen; clear 2>/dev/null || true
    st=$(stty -g 2>/dev/null) || st=""
    "$@"
    [ -n "$st" ] && stty "$st" 2>/dev/null
    [ "$1" = shield_list_menu ] || _shield_pause
    ui_flush_input
    ui_enter_screen
    ui_model_load
}
# apt-get update в фоне: экран живёт, справа — «проверяю обновления».
ui_comp_refresh_start() {
    [ -z "${UI_APTDIR:-}" ] || return 0
    osup_busy && return 0
    UI_APTDIR=$(mktemp -d "${TMPDIR:-/tmp}/goinst-apt.XXXXXX") || { UI_APTDIR=""; return 1; }
    # Своя группа процессов (set -m — в подоболочке, меню живёт без
    # управления заданиями): стоп гасит группу целиком, вместе с тем, что
    # породилось после снимка дерева. Подоболочка $( ) выходит сразу —
    # строк о завершении задания на экране нет.
    UI_APTPID=$(set -m; ( comp_refresh >/dev/null 2>&1; printf '%s|%s\n' "$?" "$COMP_REFRESH_WHY" > "$UI_APTDIR/rc.tmp" 2>/dev/null && mv -f "$UI_APTDIR/rc.tmp" "$UI_APTDIR/rc" 2>/dev/null ) </dev/null >/dev/null 2>&1 & printf '%s' "$!") || UI_APTPID=""
    case "$UI_APTPID" in ''|*[!0-9]*) UI_APTPID="" ;; esac
    return 0
}
# Фоновая проверка живёт, только пока открыт экран «Компоненты»: установщик
# продукта, самообновление и apt самого человека иначе упёрлись бы в замок
# списков apt, а после выхода из меню она висела бы до 180 с. Гасим всё:
# группу останавливаем (STOP — новых процессов не будет), снимаем дерево
# (timeout уходит в свою группу, но остаётся потомком), шлём TERM группе и
# дереву (apt убирает за собой), даём до 0,5 с и добиваем KILL. Итог уже
# записан (rc) — проверка кончилась, номер мог достаться чужому: не трогаем.
_proc_tree() { local c; printf '%s ' "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do _proc_tree "$c"; done; }
ui_comp_refresh_stop() {
    local g="${UI_APTPID:-}" t="" i
    if [ -n "$g" ] && [ ! -e "${UI_APTDIR:-/nonexistent}/rc" ]; then
        kill -STOP -- "-$g" 2>/dev/null
        t=$(_proc_tree "$g")
        # shellcheck disable=SC2086
        { kill -TERM -- "-$g"; kill -TERM $t; kill -CONT -- "-$g"; kill -CONT $t; } 2>/dev/null
        for ((i = 0; i < 10; i++)); do
            # shellcheck disable=SC2086
            { kill -0 -- "-$g" || kill -0 $t; } 2>/dev/null || break
            command sleep 0.05
        done
        # shellcheck disable=SC2086
        [ "$i" -lt 10 ] || { kill -KILL -- "-$g"; kill -KILL $t; } 2>/dev/null
    fi
    [ -n "${UI_APTDIR:-}" ] && rm -rf "$UI_APTDIR"
    UI_APTDIR=""; UI_APTPID=""
    return 0
}
ui_comp_refresh_finish() {
    local rc why
    IFS='|' read -r rc why < "$UI_APTDIR/rc" 2>/dev/null || rc=1
    rm -rf "$UI_APTDIR"; UI_APTDIR=""; UI_APTPID=""
    comp_apt_load >/dev/null 2>&1; comp_engines_load; UD_COMPUP="${COMP_NUP:-0}"
    if [ "${rc:-1}" = 0 ]; then ut "Списки apt обновлены" "The apt lists are updated"
    else ut "Проверка не вышла: ${why:-?} — показываю по прежним спискам" "The check failed: ${why:-?} — showing the previous lists"; fi
    UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 6 ))
}
# Что обновить: отмеченные, без отметок — строка под курсором с обновлением.
ui_comp_plan() {  # ui_comp_plan <cupd|call>
    local i sel="" pkgs a stopped=""
    # Проверка списков ещё идёт — не ждём её (до 180 с, а при недоступных
    # зеркалах впустую): прерываем и обновляем по прежним спискам, о чём и
    # говорим.
    if [ -n "${UI_APTDIR:-}" ]; then ui_comp_refresh_stop; comp_apt_load >/dev/null 2>&1; comp_engines_load; UD_COMPUP="${COMP_NUP:-0}"; stopped=1; fi
    for ((i = 0; i < ${#CA_ID[@]}; i++)); do
        if [ "$1" = call ]; then [ -n "${CA_UP[$i]}" ] && sel+="${sel:+ }$i"
        else case "$UI_CMARK" in *" ${CA_ID[$i]} "*) [ -n "${CA_UP[$i]}" ] && sel+="${sel:+ }$i" ;; esac; fi
    done
    if [ "$1" = cupd ] && [ "$UI_CMARK" = " " ]; then
        a="${IT_ACT[$UI_CUR]:-}"
        case "$a" in cmark:*) i="${a#cmark:}"; [ -n "${CA_UP[$i]}" ] && sel="$i" ;; esac
        if [ -z "$sel" ]; then ut "Отметьте компоненты: Пробел или Enter" "Mark the components: Space or Enter"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 )); return 0; fi
    fi
    if [ -z "$sel" ]; then ut "Обновлять нечего" "Nothing to update"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 )); return 0; fi
    UI_CSEL="$sel"
    # shellcheck disable=SC2086
    pkgs=$(comp_pkgs $sel)
    ut "Пробный прогон apt…" "apt dry run…"; UI_NOTE="$UI_TX"; ui_draw
    # shellcheck disable=SC2086
    comp_dry $pkgs
    UI_NOTE=""
    ui_go compconfirm 0
    if [ -n "$stopped" ]; then
        comp_lists_when
        ut "Проверку обновлений прервал — по прежним спискам" "Stopped the update check — using the previous lists"
        UI_NOTE="$UI_TX${COMP_LISTS_TXT:+ ($COMP_LISTS_TXT)}"; UI_NOTE_T=$(( SECONDS + 6 ))
    fi
}
# Обновление: экран отдаётся apt, как установщику продукта; потом — итог и
# снова «Компоненты» со свежими данными и без отметок.
ui_comp_run() {
    local st rc=0 i ids="" pkgs
    for i in $UI_CSEL; do ids+="${ids:+ }${CA_ID[$i]}"; done
    # shellcheck disable=SC2086
    pkgs=$(comp_pkgs $UI_CSEL)
    ui_leave_screen; clear 2>/dev/null || true
    st=$(stty -g 2>/dev/null) || st=""
    print_header "$(bi "Обновление компонентов" "Updating the components"): ${ids}"
    # shellcheck disable=SC2086
    comp_before $UI_CSEL
    # shellcheck disable=SC2086
    comp_run $pkgs || rc=$?
    [ -n "$st" ] && stty "$st" 2>/dev/null
    echo "" >&2
    # shellcheck disable=SC2086
    comp_after "$rc" $ids
    echo -ne "  $(bi "Нажмите Enter — вернуться" "Press Enter to return") " >&2; read -r || true
    ui_flush_input
    UI_CMARK=" "; UI_CSEL=""
    comp_engines_load; UD_COMPUP="${COMP_NUP:-0}"
    ui_enter_screen
    ui_back_to comps; ui_draw
    ui_model_load
}

# ── Обновление Ubuntu ──────────────────────────────────────────────────
# Экран osupg: предупреждение (до запуска), ход (раз в 2 с — только чтение
# state и log), прервано, итог. Курсор по умолчанию — «Назад»: Enter не
# должен запускать обновление ОС.
ui_osup_guard() {  # rc 0 — идёт обновление, действие отменено заметкой
    osup_busy || return 1
    UI_NOTE=$(osup_busy_text); UI_NOTE_T=$(( SECONDS + 6 ))
    return 0
}
# Пересчитать пункт «o» и его строки в UD_PROB без пересборки всей модели.
ui_osup_sync() {
    local n="${UD_OSUPN:-0}"
    osup_model; osup_probs
    UD_PROB=(${OSUP_PROBS[@]+"${OSUP_PROBS[@]}"} ${UD_PROB[@]+"${UD_PROB[@]:$n}"})
    UD_OSUPN=${#OSUP_PROBS[@]}
}
# Ступени цепочки: «✓ 20.04 → 22.04  31 мин» → UI_OSTEPS (сегменты).
_ui_osup_steps() {  # _ui_osup_steps <ширина подписи> [failed]
    local w="$1" fl="${2:-}" i l tt se now
    UI_OSTEPS=(); now=$(_osup_now)
    osup_progress
    for ((i = 0; i < ${#OSUP_PLAN[@]}; i++)); do
        l="${OSUP_PLAN[$i]}"; osup_step_title "$l"; ui_padr "$UI_TX" "$w"; tt="$UI_P"
        if osup_step_done "$l"; then
            se="${OSU[t:$l]}"; osup_dur $(( ${se#* } - ${se%% *} ))
            UI_OSTEPS+=("text${UI_US}  ${UI_RS}ok${UI_US}✓ ${UI_RS}text${UI_US}${tt}${UI_RS}muted${UI_US}  ${UI_TX}${UI_RS}")
        elif [ "$l" = "$OSUP_CUR" ] && [ -n "$fl" ]; then
            UI_OSTEPS+=("text${UI_US}  ${UI_RS}err${UI_US}✗ ${UI_RS}title${UI_US}${tt}${UI_RS}")
        elif [ "$l" = "$OSUP_CUR" ]; then
            osup_dur $(( now - OSUP_CURT )); ut "идёт ${UI_TX}" "running ${UI_TX}"
            UI_OSTEPS+=("text${UI_US}  ${UI_RS}cursor${UI_US}● ${UI_RS}title${UI_US}${tt}${UI_RS}cursor${UI_US}  ${UI_TX} ${UI_SPIN:-⠋}${UI_RS}")
        else
            UI_OSTEPS+=("text${UI_US}  ${UI_RS}muted${UI_US}○ ${tt}${UI_RS}")
        fi
    done
}
# Карточка пункта «o» в главном меню → UI_OCL, UI_OCT (заголовок), UI_OCR (метка).
ui_osup_cardlines() {  # ui_osup_cardlines <W>
    local W="$1" l i k=0 a b
    UI_OCL=(); UI_OCT="title${UI_US}Ubuntu${UI_RS}"; UI_OCR=""
    _oc() { UI_OCL+=("$1"); }
    _ocw() {  # _ocw <метка> <токен> <текст> — строка «МЕТКА  текст» с переносом
        local lab="$1" tok="$2" first=1
        ui_wrap "$3" $(( W - 10 ))
        for l in "${UI_WRAP[@]}"; do
            if [ "$first" = 1 ]; then ui_padr "$lab" 10; else ui_padr "" 10; fi
            _oc "muted${UI_US}${UI_P}${UI_RS}${tok}${UI_US}${l}${UI_RS}"; first=0
        done
    }
    case "${UD_OSUP:-}" in
        can|cont)
            UI_OCT="title${UI_US}Ubuntu ${OS_VER}${UI_RS}"
            ut "Обновить систему до Ubuntu ${OSUP_TARGET} LTS" "Upgrade the system to Ubuntu ${OSUP_TARGET} LTS"; _oc "text${UI_US}${UI_TX}${UI_RS}"
            if [ "$UD_OSUP" = cont ]; then
                ut "контейнер" "container"; UI_OCR="muted${UI_US}${UI_TX}${UI_RS}"; _oc ""
                ut "Это контейнер (${OSUP_VIRT:-?}): ядро задаёт хостер, обновить выпуск отсюда нельзя." "This is a container (${OSUP_VIRT:-?}): the host sets the kernel, the release cannot be upgraded from here."
                ui_wrap "$UI_TX" "$W"; for l in "${UI_WRAP[@]}"; do _oc "warn${UI_US}${l}${UI_RS}"; done
                ut "Переустановите сервер на ${OSUP_TARGET} в панели хостера." "Reinstall the server with ${OSUP_TARGET} in the hosting panel."
                ui_wrap "$UI_TX" "$W"; for l in "${UI_WRAP[@]}"; do _oc "muted${UI_US}${l}${UI_RS}"; done
                return 0
            fi
            if [ "$OS_VER" = 20.04 ]; then ut "↑ 2 шага" "↑ 2 steps"; a="20.04 → 22.04 → ${OSUP_TARGET}"; else ut "↑ 1 шаг" "↑ 1 step"; a="${OS_VER} → ${OSUP_TARGET}"; fi
            UI_OCR="update${UI_US}${UI_TX}${UI_RS}"
            ut "одной кнопкой: ${a}" "with one key: ${a}"; _oc "muted${UI_US}${UI_TX}${UI_RS}"; _oc ""
            ut "ЗАЧЕМ" "WHY"; _ocw "$UI_TX" text "${UD_OSUPWHY:-}"
            if [ "$OS_VER" = 20.04 ]; then ut "20–60 мин, 2–4 перезагрузки" "20–60 min, 2–4 reboots"; else ut "15–40 мин, 1–2 перезагрузки" "15–40 min, 1–2 reboots"; fi
            b="$UI_TX"; ut "ЗАЙМЁТ" "TAKES"; _ocw "$UI_TX" text "$b"
            ut "снимок сервера у хостера" "a server snapshot at the host"; b="$UI_TX"; ut "СНАЧАЛА" "FIRST"; _ocw "$UI_TX" warn "$b"
            ut "останутся на месте" "stay in place"; b="$UI_TX"; ut "ПРОДУКТЫ" "PRODUCTS"; _ocw "$UI_TX" text "$b" ;;
        run)
            osup_load; osup_progress
            ut "Ubuntu: обновление" "Ubuntu: upgrade"; UI_OCT="warn${UI_US}${UI_TX}${UI_RS}"
            ut "шаг ${OSUP_N} из ${OSUP_M}" "step ${OSUP_N} of ${OSUP_M}"; UI_OCR="warn${UI_US}${UI_TX}${UI_RS}"
            _ui_osup_steps $(( W - 16 ))
            for l in "${UI_OSTEPS[@]}"; do _oc "${l#"text${UI_US}  ${UI_RS}"}"; done
            _oc ""; ut "SSH может отключаться — это нормально" "SSH may drop out — that is normal"; _oc "muted${UI_US}${UI_TX}${UI_RS}" ;;
        fail)
            osup_load
            ut "Ubuntu: обновление" "Ubuntu: upgrade"; UI_OCT="err${UI_US}${UI_TX}${UI_RS}"
            ut "✗ прервано" "✗ interrupted"; UI_OCR="err${UI_US}${UI_TX}${UI_RS}"
            ut "Обновление прервано:" "The upgrade was interrupted:"; _oc "err${UI_US}${UI_TX}${UI_RS}"
            ui_wrap "${OSU[msg]:-?}" "$W"; for ((i = 0; i < ${#UI_WRAP[@]} && i < 6; i++)); do _oc "text${UI_US}${UI_WRAP[$i]}${UI_RS}"; done
            _oc ""; ut "журнал: " "log: "; _oc "muted${UI_US}${UI_TX}${UI_RS}text${UI_US}${OSUP_LOG}${UI_RS}" ;;
        done)
            osup_load
            UI_OCT="title${UI_US}Ubuntu ${OSUP_TARGET}${UI_RS}"; ut "✓ готово" "✓ done"; UI_OCR="ok${UI_US}${UI_TX}${UI_RS}"
            ut "Ubuntu обновлена: " "Ubuntu upgraded: "; _oc "ok${UI_US}✓ ${UI_RS}text${UI_US}${UI_TX}${OSU[to]:-${OSUP_TARGET}}${UI_RS}"
            osup_dur $(( ${OSU[finished]:-0} - ${OSU[started]:-0} )); a="$UI_TX"; ut "за ${a}" "in ${a}"; _oc "muted${UI_US}  ${UI_TX}${UI_RS}"; _oc ""
            k=${#OSU_NOTES[@]}
            if [ "$k" -gt 0 ]; then ut "замечаний: ${k}" "notes: ${k}"; _oc "warn${UI_US}! ${UI_TX}${UI_RS}"
            else ut "замечаний нет" "no notes"; _oc "ok${UI_US}✓ ${UI_TX}${UI_RS}"; fi
            ut "Enter — итог" "Enter — the result"; _oc "muted${UI_US}${UI_TX}${UI_RS}" ;;
    esac
    return 0
}
# Войти на экран. До запуска — проверка сервера (без ожидания замка).
ui_osupg_open() {
    local cur=0
    osup_load
    case "${OSU[status]:-}" in
        running|done) ui_go osupg 0 ;;
        # Курсор — на «Назад»: Enter не повторяет и не снимает отметку.
        failed) cur=1; [ "${OSU[attempt]:-1}" -lt 3 ] && cur=2; ui_go osupg "$cur" ;;
        *)  [ -n "${UD_OSUP:-}" ] || return 0
            ut "Проверяю сервер…" "Checking the server…"; UI_NOTE="$UI_TX"; ui_draw
            osup_check 0; UI_NOTE=""
            [ "$OSUP_BAD" -eq 0 ] && cur=1
            ui_go osupg "$cur" ;;
    esac
    return 0
}
# «1» на предупреждении или «Попробовать снова».
ui_osup_start() {
    ut "Запускаю обновление…" "Starting the upgrade…"; UI_NOTE="$UI_TX"; ui_draw
    if osup_start 2>/dev/null; then
        UI_NOTE=""; UI_CUR=0; UI_OSUP_T=$SECONDS
    else
        UI_NOTE="${OSUP_ERR:-?}"; UI_NOTE_T=$(( SECONDS + 8 ))
        osup_load || true
        [ "${OSU[status]:-}" = failed ] || osup_check 0
    fi
    ui_osup_sync
}
# Строки журнала для экрана: без управляющих символов, последние N.
_ui_osup_tail() {
    local e; e=$(printf '\033')
    tail -n 60 "$OSUP_LOG" 2>/dev/null | tr '\r' '\n' | LC_ALL=C sed "s/${e}\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n "${1:-3}"
}
ui_scr_osupg() {  # ui_scr_osupg <cur>
    local st W=$(( UI_C - 4 )) M=() l i k a b g t h max sw=30 ins
    UI_CUR="$1"; UI_BODY=(); UI_INFO=""; UI_KEYS=""; UI_OSUPRUN=0
    [ "$UI_C" -lt 60 ] && sw=22
    _osupg_w() {  # _osupg_w <токен значка> <значок> <токен текста> <текст> — с переносом
        local first=1
        ui_wrap "$4" $(( W - 2 ))
        for l in "${UI_WRAP[@]}"; do
            if [ "$first" = 1 ]; then M+=("text${UI_US}  ${UI_RS}$1${UI_US}$2 ${UI_RS}$3${UI_US}${l}${UI_RS}"); else M+=("text${UI_US}    ${UI_RS}$3${UI_US}${l}${UI_RS}"); fi
            first=0
        done
    }
    osup_load; st="${OSU[status]:-}"
    ui_items_clear
    case "$st" in
        running)
            UI_OSUPRUN=1
            ut "Обновление Ubuntu идёт" "Ubuntu upgrade is running"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "${UD_HOST:-} · $(printf '%(%H:%M)T' -1)"; ui_body ""
            _ui_osup_steps "$sw"; M+=("${UI_OSTEPS[@]}"); M+=("")
            ut "Последнее из журнала:" "Latest from the log:"; M+=("muted${UI_US}  ${UI_TX}${UI_RS}")
            while IFS= read -r l; do M+=("muted${UI_US}    ${l}${UI_RS}"); done < <(_ui_osup_tail 3)
            ut "Журнал: " "Log: "; M+=("muted${UI_US}  ${UI_TX}${UI_RS}text${UI_US}${OSUP_LOG}${UI_RS}"); M+=("")
            # Признак зависания — словами; ничего не убиваем.
            if osup_stall; then _osupg_w warn '!' warn "$OSUP_STALLTX"; M+=(""); fi
            ut "Сервер перезагрузится сам. SSH можно закрыть — обновление продолжится. Ход виден при входе по SSH и здесь, в goinstall." "The server reboots by itself. You can close SSH — the upgrade goes on. The progress shows at SSH login and here, in goinstall."
            ui_wrap "$UI_TX" "$W"; for l in "${UI_WRAP[@]}"; do M+=("text${UI_US}  ${l}${UI_RS}"); done
            ui_item_back
            ut "назад · экран обновляется сам раз в 2 с" "back · the screen refreshes every 2 s"; a="$UI_TX"; ut "назад" "back"; ui_keys_fit "0|$a|$UI_TX" ;;
        failed)
            ut "Обновление Ubuntu прервано" "Ubuntu upgrade interrupted"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "${UD_HOST:-}"; ui_body ""
            _osupg_w err '✗' text "${OSU[msg]:-?}"
            ut "попытка ${OSU[attempt]:-1} из 3 · журнал: " "attempt ${OSU[attempt]:-1} of 3 · log: "; M+=("muted${UI_US}    ${UI_TX}${UI_RS}text${UI_US}${OSUP_LOG}${UI_RS}"); M+=("")
            _ui_osup_steps "$sw" failed; M+=("${UI_OSTEPS[@]}")
            if [ "${OSU[attempt]:-1}" -lt 3 ]; then ut "Попробовать снова" "Try again"; ui_item 1 "$UI_TX" osupretry; fi
            # «Обновлять не буду»: иначе отметка висела бы вечно — и в меню,
            # и при каждом входе.
            ut "Убрать отметку — обновлять не буду" "Clear the mark — I will not upgrade"; ui_item 2 "$UI_TX" osupdrop
            ui_item_back
            ut "снова" "retry"; a="$UI_TX"; ut "убрать" "clear"; b="$UI_TX"; ut "назад" "back"
            if [ "${OSU[attempt]:-1}" -lt 3 ]; then ui_keys_fit "↑↓||" "Enter||" "1|$a|" "2|$b|" "0|$UI_TX|$UI_TX"; else ui_keys_fit "↑↓||" "Enter||" "2|$b|" "0|$UI_TX|$UI_TX"; fi ;;
        done)
            osup_mark_seen; [ "${UD_OSUP:-}" = done ] && ui_osup_sync
            ut "Ubuntu обновлена до ${OSUP_TARGET}" "Ubuntu upgraded to ${OSUP_TARGET}"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "${UD_HOST:-}"; ui_body ""
            osup_dur $(( ${OSU[finished]:-0} - ${OSU[started]:-0} )); a="$UI_TX"
            ut "за ${a} · запусков службы ${OSU[reboots]:-?}" "in ${a} · ${OSU[reboots]:-?} unit runs"
            M+=("text${UI_US}  ${UI_RS}ok${UI_US}✓ ${UI_RS}name${UI_US}${OSU[to]:-Ubuntu ${OSUP_TARGET}}${UI_RS}muted${UI_US} · ${UI_TX}${UI_RS}"); M+=("")
            if [ "${#OSU_DID[@]}" -gt 0 ]; then
                ut "Сделано:" "Done:"; M+=("muted${UI_US}  ${UI_TX}${UI_RS}")
                for t in "${OSU_DID[@]}"; do _osupg_w muted '·' text "$t"; done
            fi
            comp_bots_load; comp_bot_probs
            if [ "${#OSU_NOTES[@]}" -gt 0 ] || [ "${#COMP_BOTP[@]}" -gt 0 ]; then
                ut "Замечания:" "Notes:"; M+=("muted${UI_US}  ${UI_TX}${UI_RS}")
                for t in ${OSU_NOTES[@]+"${OSU_NOTES[@]}"} ${COMP_BOTP[@]+"${COMP_BOTP[@]}"}; do
                    IFS='|' read -r a b i h k <<<"$t"
                    if [ "$k" = err ]; then g='✗'; i=err; else g='!'; i=warn; fi
                    _osupg_w "$i" "$g" text "${a}: ${b} → ${h}"
                done
            else ut "замечаний нет" "no notes"; M+=("text${UI_US}  ${UI_RS}ok${UI_US}✓ ${UI_RS}text${UI_US}${UI_TX}${UI_RS}"); fi
            ui_item_back
            ut "назад" "back"; ui_keys_fit "0|$UI_TX|$UI_TX" ;;
        *)
            ut "Обновление Ubuntu" "Ubuntu upgrade"; ui_hdr "title${UI_US}${UI_TX}${UI_RS}" "${UD_HOST:-}"; ui_body ""
            UI_SEG=""; _s text "  "; _s name "${OS_PRETTY:-Ubuntu ${OS_VER}}"
            [ "$OS_VER" = 20.04 ] && { _s muted "  →  "; _s text "22.04"; }
            _s muted "  →  "; _s update "${OSUP_TARGET} LTS"; M+=("$UI_SEG")
            if [ "$OS_VER" = 20.04 ]; then ut "Два шага штатной программой Ubuntu, 20–60 минут, перезагрузки 2–4." "Two steps with Ubuntu's own upgrader, 20–60 minutes, 2–4 reboots."
            else ut "Один шаг штатной программой Ubuntu, 15–40 минут, перезагрузки 1–2." "One step with Ubuntu's own upgrader, 15–40 minutes, 1–2 reboots."; fi
            a="$UI_TX"; ut "SSH будет отключаться, на последнем шаге — до 10 минут. Это нормально, обновление идёт само." "SSH drops out, on the last step for up to 10 minutes. That is normal, the upgrade goes on by itself."
            ui_wrap "$a $UI_TX" "$W"; for l in "${UI_WRAP[@]}"; do M+=("text${UI_US}  ${l}${UI_RS}"); done
            M+=("")
            # Рамка «! Сначала бэкап».
            ui_lclear
            ut "Сделайте снимок (бэкап) сервера в панели хостера. Если обновление прервётся, вернуть сервер можно только из снимка." "Take a snapshot (backup) of the server in the hosting panel. If the upgrade breaks off, the server can only be restored from the snapshot."
            ui_wrap "$UI_TX" $(( W - 4 )); for l in "${UI_WRAP[@]}"; do ui_lpush "text${UI_US} ${l}${UI_RS}" 0; done
            ut "! Сначала бэкап" "! Backup first"; ui_frame2 $(( W - 1 )) "${#UI_WRAP[@]}" "warn${UI_US}${UI_TX}${UI_RS}" ""
            for ((i = 0; i < ${#UI_FR[@]}; i++)); do if [ "$i" = 0 ]; then g=" "; else g="░"; fi; M+=("text${UI_US}  ${UI_RS}${UI_FR[$i]}shadow${UI_US}${g}${UI_RS}"); done
            ui_rep '░' $(( W - 1 )); M+=("text${UI_US}   ${UI_RS}shadow${UI_US}${UI_P}${UI_RS}"); M+=("")
            # Проверка: препятствия, замечания, что сделает сам, ✓ одной строкой, сведения.
            for k in "${OSUP_CHK[@]}"; do case "$k" in bad\|*) _osupg_w err '✗' text "${k#*|}" ;; esac; done
            for k in "${OSUP_CHK[@]}"; do case "$k" in warn\|*) _osupg_w warn '!' text "${k#*|}" ;; esac; done
            ins=0
            for k in "${OSUP_CHK[@]}"; do case "$k" in do\|*)
                [ "$ins" = 0 ] && { ut "goInstaller сделает сам:" "goInstaller will do itself:"; M+=("muted${UI_US}  ${UI_TX}${UI_RS}"); ins=1; }
                _osupg_w ok '✓' text "${k#*|}" ;; esac; done
            UI_SEG=""; _s text " "; h=1
            for k in "${OSUP_CHK[@]}"; do case "$k" in ok\|*)
                t="${k#*|}"; ui_len "$UI_SEG"
                if [ $(( UI_N + ${#t} + 4 )) -gt "$W" ] && [ "$h" = 0 ]; then M+=("$UI_SEG"); UI_SEG=""; _s text " "; fi
                _s text " "; _s ok "✓ "; _s text "$t"; h=0 ;; esac; done
            [ "$h" = 0 ] && M+=("$UI_SEG")
            for k in "${OSUP_CHK[@]}"; do case "$k" in info\|*) _osupg_w muted '·' muted "${k#*|}" ;; esac; done
            if [ "$OSUP_BAD" -eq 0 ]; then ut "Бэкап сделан — обновить до ${OSUP_TARGET}" "The backup is done — upgrade to ${OSUP_TARGET}"; ui_item 1 "$UI_TX" osupgo; fi
            ui_item_back
            ut "обновить" "upgrade"; a="$UI_TX"; ut "назад" "back"
            if [ "$OSUP_BAD" -eq 0 ]; then ui_keys_fit "↑↓||" "Enter||" "1|$a|" "0|$UI_TX|$UI_TX"; else ui_keys_fit "0|$UI_TX|$UI_TX"; fi ;;
    esac
    [ "$UI_CUR" -lt "${#IT_KEY[@]}" ] || UI_CUR=$(( ${#IT_KEY[@]} - 1 ))
    # Пункты должны остаться на экране: лишнее внизу текста — «…».
    max=$(( UI_R - ${#UI_BODY[@]} - 1 - ${#IT_KEY[@]} - 1 ))
    if [ "${#M[@]}" -gt "$max" ]; then M=("${M[@]:0:$(( max - 1 ))}"); M+=("muted${UI_US}  …${UI_RS}"); fi
    for l in "${M[@]}"; do ui_body "$l"; done
    ui_body ""
    ui_choicerows "$UI_CUR"
}

# Пункты текущего экрана — те же, что нарисованы: действие по ключу берётся
# из IT_*/MI_* после ui_draw.
ui_items_count() { if [ "$UI_SCR" = menu ]; then UI_NI="${#MI_KEY[@]}"; else UI_NI="${#IT_KEY[@]}"; fi; }
ui_item_act() {  # ui_item_act <номер пункта>
    local i="$1"
    if [ "$UI_SCR" = menu ]; then
        case "${MI_KIND[$i]}" in
            p) UI_WP="${MI_P[$i]}"; ui_mark_seen "${PRODUCTS[${MI_P[$i]}]}"; ui_go product 0 ;;
            *) case "${MI_KEY[$i]}" in 7) ui_ports_load; ui_go ports 0 ;; 8) ui_go key 0 ;; 9) ui_go lang "$([ "${LANG_CODE:-ru}" = en ] && echo 1 || echo 0)" ;; u) ui_go selfupd 0 ;; c) ui_comps_open ;; s) ui_shield_open ;; o) ui_osupg_open ;; x) ui_osup_guard || ui_go uninstall 0 ;; 0) UI_SCR=quit ;; esac ;;
        esac
        return 0
    fi
    ui_act "${IT_ACT[$i]}"
}
# Выбор пункта по ключу: цифра или буква пункта (горячая клавиша меню).
ui_item_by_key() {  # ui_item_by_key <символ> → UI_I или rc 1
    local k="$1" i
    ui_items_count
    for ((i = 0; i < UI_NI; i++)); do
        if [ "$UI_SCR" = menu ]; then
            if [ "${MI_KEY[$i]}" = "$k" ] || { [ -n "${MI_HOT[$i]}" ] && [ "${MI_HOT[$i]}" = "$k" ]; }; then UI_I=$i; return 0; fi
        elif [ "${IT_KEY[$i]}" = "$k" ]; then UI_I=$i; return 0; fi
    done
    return 1
}

# Мастер установки: режим → проверка → ветка → подтверждение → установка → сверка.
ui_wizard() {  # ui_wizard <индекс продукта>
    local p="$1" id="${PRODUCTS[$1]}" m
    UI_WP="$p"; UI_WIZ=1; UI_ONLY=0; UI_PMODE=""; UI_PBRANCH=""
    if [ -n "${UD_MODES[$p]:-}" ]; then
        # Режим стоящего продукта записан в его настройках — не спрашиваем.
        if [ "${UD_INST[$p]:-0}" = 1 ] && [ "${UD_ST[$p]}" != free ] && m=$(prod_installed_mode "$id" 2>/dev/null); then
            UI_PMODE="$m"; ui_pf_load "$id" "$m"; ui_go check 0
        else
            ui_modes_load "$p"; ui_go mode 0
            local i=0 x; for x in ${UD_MODES[$p]}; do [ "$x" = "${UD_DEFMODE[$p]}" ] && UI_CUR=$i; i=$(( i + 1 )); done
        fi
    else ui_pf_load "$id" pro; ui_go check 0; fi
}
ui_check_only() {  # ui_check_only <индекс продукта>
    local p="$1" id="${PRODUCTS[$1]}" m
    UI_WP="$p"; UI_WIZ=0
    if [ -n "${UD_MODES[$p]:-}" ]; then
        if [ "${UD_INST[$p]:-0}" = 1 ] && m=$(prod_installed_mode "$id" 2>/dev/null); then UI_PMODE="$m"; ui_pf_load "$id" "$m"; ui_go check 0
        else UI_ONLY=1; ui_modes_load "$p"; ui_go mode 0; fi
    else UI_PMODE=""; ui_pf_load "$id" pro; ui_go check 0; fi
}
# Запуск установщика продукта: экран отдаётся ему, после — сверка.
ui_run_installer() {
    local p="$UI_WP" id="${PRODUCTS[$UI_WP]}" rc got m st
    ui_comp_refresh_stop   # установщик сам зовёт apt-get: замок списков должен быть свободен
    ui_leave_screen; clear 2>/dev/null || true
    st=$(stty -g 2>/dev/null) || st=""
    MODE="${UI_PMODE:-pro}"; REF="${UI_PBRANCH:-$(prod_ref "$id")}"
    free_takeover_note "$id"
    run_product_installer "$id"; rc=$?
    [ -n "$st" ] && stty "$st" 2>/dev/null
    echo ""
    if [ "$rc" -eq 0 ]; then ok "$(bi "Установщик $(prod_name "$id") завершился." "The $(prod_name "$id") installer has finished.")"
    else warn "$(bi "Установщик $(prod_name "$id") вышел с кодом ${rc}." "The $(prod_name "$id") installer exited with code ${rc}.")"; fi
    shield_postcheck "$id"
    echo -ne "  $(bi "Нажмите Enter — сверка итога" "Press Enter — verify the result") "; read -r || true
    ui_flush_input
    say "$(bi "Сверяю итог…" "Verifying the result…")"
    ui_model_load
    UI_MISM=0; UI_LAZYMODE=""; UI_PC_ST=""; UI_PC_TX=""; UI_PC_RC=0; UI_PC_HAVE=""
    # Та же проверка, что у --install и нумерованного меню.
    installer_verdict "$id" "$REF" "$rc" 2>/dev/null
    case "$PC_WHY" in
        ok)  if [ "$MODE" = lazy ] && m=$(prod_installed_mode "$id" 2>/dev/null); then UI_LAZYMODE="$m"; fi ;;
        ref) UI_MISM=1 ;;
        *)   UI_PC_ST="$PC_ST"; UI_PC_TX="$PC_TX"; UI_PC_RC="$PC_RC"; UI_PC_HAVE="$PC_HAVE" ;;
    esac
    ui_enter_screen
    ui_back_to product; ui_go result 0
}
# Открыть меню самого продукта: его команда в обычном терминале.
ui_open_product() {
    local cmd="${UD_CMD[$UI_WP]}" st
    ui_leave_screen; clear 2>/dev/null || true
    # Настройки терминала — до продукта и назад после: меню продукта может
    # оставить его «сырым» (без icrnl), и построчный read («Нажмите Enter»)
    # тогда ждал бы Ctrl-J вместо Enter.
    st=$(stty -g 2>/dev/null) || st=""
    if command -v "$cmd" >/dev/null 2>&1; then "$cmd" || true
    else warn "$(bi "Команды ${cmd} нет в PATH — запустите обновление." "Command ${cmd} is not in PATH — run the update.")"; sleep 2; fi
    [ -n "$st" ] && stty "$st" 2>/dev/null
    # Экран — сразу, сведения — потом: пересборка занимает секунды, и
    # пустое окно всё это время выглядело зависшим.
    ui_flush_input
    ui_enter_screen; ui_draw; ui_model_load
}

ui_act() {  # ui_act <действие пункта>
    local a="$1" id
    case "$a" in
        back) ui_back ;;
        # С итога установки — в меню на тот же продукт, а не на первый.
        root) local was="$UI_SCR"; ui_root menu; [ "$was" = result ] && [ -n "${UI_WP:-}" ] && UI_CUR="$UI_WP" ;;
        quit) UI_SCR=quit ;;
        # Меню продукта умеет обновляться и ставить пакеты — во время
        # обновления Ubuntu так же нельзя, как мастер.
        openprod) ui_osup_guard || ui_open_product ;;
        wizard) ui_osup_guard || { ui_need_key && ui_wizard "$UI_WP"; } ;;
        check) ui_check_only "$UI_WP" ;;
        othermode) UI_ONLY=1; ui_modes_load "$UI_WP"; ui_go mode 0 ;;
        mode:*) UI_PMODE="${a#mode:}"; ui_pf_load "${PRODUCTS[$UI_WP]}" "$UI_PMODE"; ui_go check 0 ;;
        continue) ui_need_key || return 0
                  if [ -n "${UD_DEV[$UI_WP]:-}" ]; then
                      if [ "${UD_INST[$UI_WP]:-0}" = 1 ] && [ "${UD_BRANCH[$UI_WP]:-main}" = "${UD_DEVREF[$UI_WP]:-dev}" ]; then ui_go branch 1; else ui_go branch 0; fi
                  else UI_PBRANCH="main"; ui_go confirm 0; fi ;;
        branch:*) UI_PBRANCH="${a#branch:}"; ui_go confirm 0 ;;
        yes) ui_osup_guard || { ui_need_key && ui_run_installer; } ;;
        nokeygo) ui_root menu
                 ut "Продолжаю без ключа: доступны проверка портов и карта портов" "Continuing without a key: the port check and the port map still work"
                 UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 6 )) ;;
        no) ui_back_to product ;;
        group:*) UI_CUR="${a#group:}" ;;
        keycheck) token_check; UI_KEYAT=$(date +%H:%M); ui_model_load ;;
        keyinput) UI_KEYBUF=""; UI_KEYST=""; UI_INPUT=1; ui_go keyinput 0 ;;
        keyforget) token_forget; TOKEN=""; TOKEN_STATUS=""; ui_root nokey ;;
        lang:*) LANG_CODE="${a#lang:}"; LANG_ASKED=yes; lang_persist; ui_model_load; ui_back ;;
        retry) ui_poll_start && ui_root splash ;;
        sumyes) summary_enable; ui_first_screen ;;
        sumno) summary_disable; ui_first_screen ;;
        uninstall_drop|uninstall_keep)
            # Удаление — после выхода из экрана: сам скрипт после него
            # продолжать нечем.
            ui_osup_guard && return 0
            UI_UNINSTALL="${1#uninstall_}"; UI_SCR=quit ;;
        # Обновление Ubuntu: запуск после предупреждения и повтор после сбоя.
        osupgo|osupretry) ui_osup_start ;;
        osupdrop) if osup_dismiss; then ut "Отметка снята. Журнал остался: ${OSUP_LOG}" "The mark is cleared. The log stays: ${OSUP_LOG}"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 6 )); fi
                  ui_osup_sync; ui_root menu ;;
        # Компоненты: отметить строку, план, обновление, проверка списков.
        cmark:*) id="${CA_ID[${a#cmark:}]}"
                 case "$UI_CMARK" in *" $id "*) UI_CMARK="${UI_CMARK/ $id / }" ;; *) UI_CMARK+="$id " ;; esac ;;
        cinfo:*) ;;
        cupd|call) ui_osup_guard || ui_comp_plan "$a" ;;
        cref) if ui_osup_guard; then :
              elif [ -n "${UI_APTDIR:-}" ]; then ut "Проверка уже идёт" "The check is already running"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 ))
              elif [ "${COMP_APT:-0}" = 1 ]; then ui_comp_refresh_start
              else ut "apt недоступен — проверять нечем" "apt is unavailable — nothing to check with"; UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 )); fi ;;
        cyes) ui_comp_run ;;
        # Защита от сканеров: каждое действие — в обычном терминале.
        sh:on) ui_shield_run shield_do_on ;;
        sh:scan) ui_shield_run shield_do_scan ;;
        sh:vk) ui_shield_run shield_do_vk ;;
        sh:update) ui_shield_run shield_do_update ;;
        sh:exclude) ui_shield_run shield_list_menu exclude ;;
        sh:block) ui_shield_run shield_list_menu block ;;
        sh:remove) ui_shield_run shield_do_remove ;;
        sh:stats) UI_SHV=0; UI_SHR=-1; ui_go shstats 0 ;;
        sh:top) UI_SHV=0; UI_SHT=0; ui_go shtop 0 ;;
        sh:set) UI_SHH=main; UI_SHC=0; ui_go shset 0 ;;
        selfyes) ui_osup_guard && return 0; ui_comp_refresh_stop
                 ui_leave_screen; clear 2>/dev/null || true; self_update "${UD_SELFREF:-$GOINST_SELF_REF}"; echo -ne "  $(bi "Нажмите Enter" "Press Enter") "; read -r || true
                 if [ -x "$GOINST_BIN" ]; then exec "$GOINST_BIN"; fi; UI_SCR=quit ;;
    esac
}

# Первый экран: нет ключа — ввод ключа; сведения свежие — меню; иначе
# заставка с опросом GitHub.
ui_first_screen() {
    if [ -z "${TOKEN:-}" ]; then ui_root nokey
    elif [ -n "${GOINST_NO_NET:-}" ]; then ui_root menu
    elif ver_cache_read "${PRODUCTS[0]}" main >/dev/null 2>&1; then ui_root menu
    elif ui_poll_start; then ui_root splash
    else ui_root menu; fi
}

# Главный цикл «Аркады».
ui_main() {
    local t0 tick=0.5 last_poll=$SECONDS refresh="${GOINST_MENU_REFRESH:-180}" n dirty=1 scr0=""
    case "$refresh" in ''|*[!0-9]*) refresh=0 ;; esac
    UI_SPINS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; UI_INPUT=0; UI_RESIZED=0
    # Компоненты apt считаются для открытой «Аркады»: счётчик «↑N» в меню.
    UI_COMPS=1
    ui_detect
    trap 'UI_RESIZED=1' WINCH
    trap 'ui_leave_screen; exit 130' INT TERM
    # Упали посреди экрана — вернуть терминал из альтернативного экрана с
    # видимым курсором, иначе человек остаётся перед пустым окном.
    trap 'ui_crash_exit' EXIT
    ui_enter_screen
    ui_model_load
    # Сводку при входе спрашиваем один раз, до первого экрана.
    if [ ! -e "$SUM_CHOICE" ] && [ -z "${GOINST_NO_SUMASK:-}" ]; then ui_root sumask; else ui_first_screen; fi
    while [ "$UI_SCR" != quit ]; do
        if [ "$UI_RESIZED" = 1 ]; then UI_RESIZED=0; ui_size; ui_tokens; dirty=1; fi
        if [ -n "${UI_NOTE:-}" ] && [ "$SECONDS" -ge "${UI_NOTE_T:-0}" ]; then UI_NOTE=""; dirty=1; fi
        # Кадр — только когда есть что менять: нажатие, опрос со спиннером,
        # новое окно. Раньше экран уходил целиком раз в секунду, а это лишние
        # килобайты в секунду по SSH с телефона.
        # Проверка списков apt идёт в фоне — спиннер только на её экране.
        local spin=0
        if [ -n "${UI_POLLDIR:-}" ] || { [ -n "${UI_APTDIR:-}" ] && [ "$UI_SCR" = comps ]; }; then spin=1; fi
        # Ход обновления Ubuntu — раз в 2 с, только чтение state и log.
        if [ "$UI_SCR" = osupg ] && [ "${UI_OSUPRUN:-0}" = 1 ] && [ $(( SECONDS - ${UI_OSUP_T:-0} )) -ge 2 ]; then dirty=1; UI_OSUP_T=$SECONDS; fi
        if [ "$dirty" = 1 ] || [ "$spin" = 1 ]; then ui_draw; fi
        dirty=0
        # Заставка и опрос: такт для спиннера; иначе — ждём клавишу, но
        # раз в секунду проверяем, не пора ли меню спросить GitHub.
        if [ "$spin" = 1 ]; then tick=0.1; else tick=1; fi
        ui_read_key "$tick"
        UI_SPINS="${UI_SPINS:1}${UI_SPINS:0:1}"
        if [ -n "${UI_APTDIR:-}" ] && [ -s "$UI_APTDIR/rc" ]; then ui_comp_refresh_finish; dirty=1; fi
        if [ -n "${UI_POLLDIR:-}" ] && ui_poll_state; then
            ui_poll_finish; last_poll=$SECONDS; dirty=1
            # Ключ отвергнут — стираем и просим новый (исчерпанный лимит сюда
            # не попадает: это состояние limited, ключ остаётся).
            if [ "${TOKEN_STATUS:-}" = bad ]; then token_forget; TOKEN=""; UI_KEYBAD=1; ui_model_load; ui_root nokey; continue; fi
            ui_model_load
            if [ "$UI_SCR" = splash ]; then if [ -n "$UI_POLLERR" ]; then ui_root err; else ui_root menu; fi; fi
        fi
        if [ "$UI_SCR" = menu ] && [ "$refresh" -gt 0 ] && [ -n "${TOKEN:-}" ] && [ -z "${UI_POLLDIR:-}" ] && [ $(( SECONDS - last_poll )) -ge "$refresh" ] && ! gh_limited >/dev/null; then
            ui_poll_start; last_poll=$SECONDS
        fi
        # ←→ на графике статистики и у карточки «Защиты» листают.
        [ -n "${UI_ARROW:-}" ] && ui_sh_arrow
        # Enter сразу после действия — «цифра, Enter» в человеческом темпе —
        # относится к прошлому экрану, а не к новому: на подтверждении он
        # запустил бы установщик, которого человек ещё не видел.
        if [ "$UI_KEY" = enter ] && [ "${UI_INPUT:-0}" = 0 ]; then
            _ui_now_ms; [ "$UI_NOW" -lt "${UI_SWALLOW_T:-0}" ] && UI_KEY=swallow
        fi
        # Журнал для набора: клавиша, экран, на котором её прочли, и продукт.
        [ -n "${GOINST_UI_TRACE:-}" ] && [ "$UI_KEY" != tick ] && printf '%s %s %s\n' "$UI_KEY" "$UI_SCR" "${UI_WP:-}" >> "$GOINST_UI_TRACE"
        if [ "$UI_KEY" = paste ]; then
            if [ "$UI_C" -lt 60 ]; then ut "Пачка клавиш пропущена — по одной" "Key burst skipped — one at a time"
            else ut "Пришло несколько клавиш разом — пропущено. Нажимайте по одной." "Several keys arrived at once — skipped. Press one at a time."; fi
            UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 )); dirty=1
        fi
        case "$UI_KEY" in tick|paste|other|swallow) continue ;; esac
        dirty=1
        # Ввод ключа: всё — символы ключа, кроме Enter, Backspace и Esc.
        if [ "$UI_SCR" = keyinput ]; then
            case "$UI_KEY" in
                esc|eof) UI_INPUT=0; UI_KEYBUF=""; UI_KEYTHEN=""; ui_back ;;
                back) UI_KEYBUF="${UI_KEYBUF%?}" ;;
                enter)
                    [ -n "$UI_KEYBUF" ] || continue
                    UI_KEYST=checking; ui_draw
                    TOKEN="$UI_KEYBUF"; TOKEN_FROM="asked"; token_check
                    case "$TOKEN_STATUS" in
                        ok|denied|nonet|limited) token_save "$UI_KEYBUF" >/dev/null 2>&1; UI_KEYST=ok; ui_draw; sleep 1
                                                 UI_INPUT=0; UI_KEYBUF=""; UI_KEYAT=$(date +%H:%M); ui_model_load
                                                 if [ -n "${UI_KEYTHEN:-}" ]; then
                                                     # Ключ брали ради установки — назад к мастеру
                                                     # продукта; версии подтянутся опросом в фоне.
                                                     n="$UI_KEYTHEN"; UI_KEYTHEN=""; ui_poll_start
                                                     ui_root menu; UI_CUR="$n"; UI_WP="$n"; ui_go product 0; ui_wizard "$n"
                                                 elif ui_poll_start; then ui_root splash; else ui_root menu; fi ;;
                        *) UI_KEYST=bad; TOKEN="" ;;
                    esac ;;
                *) UI_KEYBUF+="$UI_KEY"; UI_KEYST="" ;;
            esac
            continue
        fi
        [ "$UI_SCR_DRAWN" = small ] && { case "$UI_KEY" in q|0|esc|eof) UI_SCR=quit ;; esac; continue; }
        if [ "$UI_SCR" = splash ]; then ui_root menu; continue; fi
        scr0="$UI_SCR|${#UI_STACK[@]}"
        ui_items_count
        # Экраны статистики защиты берут свои клавиши сами (ui_sh_do).
        ui_sh_key && UI_KEY="shk:$UI_KEY"
        case "$UI_KEY" in
            shk:*) ui_sh_do "${UI_KEY#shk:}" ;;
            up)    [ "$UI_NI" -gt 0 ] && UI_CUR=$(( (UI_CUR - 1 + UI_NI) % UI_NI )); [ "$UI_SCR" = ports ] || true ;;
            down)  [ "$UI_NI" -gt 0 ] && UI_CUR=$(( (UI_CUR + 1) % UI_NI )) ;;
            enter) [ "$UI_NI" -gt 0 ] && ui_item_act "$UI_CUR" ;;
            eof)   UI_SCR=quit ;;
            esc)   if [ "$UI_SCR" = menu ]; then UI_SCR=quit; else ui_back; fi ;;
            q)     UI_SCR=quit ;;
            # Пробел — отметка строки, только на «Компонентах».
            ' ')   [ "$UI_SCR" = comps ] && [ "$UI_NI" -gt 0 ] && ui_item_act "$UI_CUR" ;;
            *)
                # На «Компонентах» действие буквой курсор не уводит: «u» без
                # отметок берёт строку под курсором.
                # Цифра отмечает строку и ставит на неё курсор: справа — её карточка.
                if [ "$UI_SCR" = comps ] && ui_item_by_key "$UI_KEY"; then case "$UI_KEY" in [1-9]) UI_CUR="$UI_I" ;; esac; ui_item_act "$UI_I"
                elif ui_item_by_key "$UI_KEY"; then UI_CUR="$UI_I"; ui_item_act "$UI_I"
                else case "$UI_KEY" in
                    0) ui_back ;;
                    p|f3) ui_ports_load; ui_go ports 0 ;;
                    # Компоненты — с любого экрана, как карта портов.
                    c) case "$UI_SCR" in comps|compconfirm) ;; *) ui_comps_open ;; esac ;;
                    s) case "$UI_SCR" in shield|shstats|shtop|shset|comps|compconfirm) ;; *) ui_shield_open ;; esac ;;
                    f2) ui_size_next; ui_size
                        case "$(ui_size_mode)" in
                            full)    ut "Размер: на всё окно (F2 — дальше)" "Size: whole window (F2 — next)" ;;
                            center)  ut "Размер: 80×24 по центру (F2 — дальше)" "Size: 80×24 centred (F2 — next)" ;;
                            compact) ut "Размер: 80×24 в углу (F2 — дальше)" "Size: 80×24 in the corner (F2 — next)" ;;
                        esac
                        UI_NOTE="$UI_TX"; UI_NOTE_T=$(( SECONDS + 4 )) ;;
                    r) [ "$UI_SCR" = key ] || ui_go key 0 ;;
                    l|f4) [ "$UI_SCR" = lang ] || ui_go lang "$([ "${LANG_CODE:-ru}" = en ] && echo 1 || echo 0)" ;;
                    u) [ -n "${UD_VERNEW:-}" ] && ui_go selfupd 0 ;;
                    o) [ -n "${UD_OSUP:-}" ] && [ "$UI_SCR" != osupg ] && ui_osupg_open ;;
                esac; fi ;;
        esac
        # После действия цифрой или буквой — и после любой смены экрана, хоть
        # Enter, хоть Esc, — Enter ещё 0,4 с ничего не жмёт: несколько Enter,
        # нажатых, пока экран думал, иначе прошли бы мастер насквозь до
        # «Да, запустить установщик».
        case "${UI_KEY#shk:}" in up|down|enter|esc|back|eof|' '|left|right|pgup|pgdn|home|end) ;; *) _ui_now_ms; UI_SWALLOW_T=$(( UI_NOW + 400 )) ;; esac
        if [ "$UI_SCR|${#UI_STACK[@]}" != "$scr0" ]; then _ui_now_ms; UI_SWALLOW_T=$(( UI_NOW + 400 )); fi
        # На карте портов курсор выбирает владельца — правое окно следует за ним.
        [ "$UI_SCR" = ports ] && [ "$UI_CUR" -lt "${#UI_PG_NAME[@]}" ] && UI_PG_CUR="$UI_CUR"
        # Ушли с «Компонентов» — фоновая проверка списков больше не нужна.
        [ -n "${UI_APTDIR:-}" ] && [ "$UI_SCR" != comps ] && ui_comp_refresh_stop
    done
    ui_leave_screen
    [ -n "${UI_POLLPID:-}" ] && kill "$UI_POLLPID" 2>/dev/null
    [ -n "${UI_POLLDIR:-}" ] && rm -rf "$UI_POLLDIR"
    ui_comp_refresh_stop
    trap - WINCH INT TERM EXIT
    return 0
}
ui_crash_exit() {
    # Ctrl-C и падение тоже не оставляют apt-get update и /tmp/goinst-apt.*,
    # и сведения портов ui_sh_model (Ctrl+C, пока считал python).
    ui_comp_refresh_stop
    [ -n "${UI_SHTMP:-}" ] && rm -f "$UI_SHTMP"
    [ "${UI_ALT:-0}" = 1 ] || return 0
    ui_leave_screen
    [ -n "${UI_POLLPID:-}" ] && kill "$UI_POLLPID" 2>/dev/null
    [ -n "${UI_POLLDIR:-}" ] && rm -rf "$UI_POLLDIR"
    printf '\n  %s\n' "$(bi "Меню goInstaller упало. Прежнее меню: GOINST_PLAIN_MENU=1 goinstall" "The goInstaller menu crashed. The previous menu: GOINST_PLAIN_MENU=1 goinstall")" >&2
    return 0
}

# ── сводка при входе и фоновый опрос ───────────────────────────────────
# Решение заказчика: фон спрашивает GitHub раз в 30 минут, открытое меню —
# раз в 3. Вход по SSH никогда не ждёт сеть: скрипт входа печатает сводку
# из файла, который пишет таймер. Всё это ставится только с согласия — это
# первый случай, когда goInstaller оставляет что-то работать на сервере.
SUM_FILE="${GOINST_SUM_FILE:-${GOINST_DIR}/summary}"
SUM_CHOICE="${GOINST_SUM_CHOICE:-${GOINST_DIR}/.summary}"
SUM_UNIT_DIR="${GOINST_SYSTEMD_DIR:-/etc/systemd/system}"
SUM_HOOK="${GOINST_PROFILE_HOOK:-/etc/profile.d/goinstall-summary.sh}"

# --watch: взять сводку версий и записать сведения для входа. Сводку клуба
# собирает GitHub Actions — это один условный запрос. Её нет (Actions ещё
# не собрал её или сломался) — спросить самому, но скромно: только стоящие
# продукты и себя, без проверки ключа. Ничего не вышло — время сведений
# остаётся прежним: «сведения от» не должно врать о свежести.
summary_watch() {
    local tmp n p id ok=0 v prev rc=0
    local -a ids=()
    summary_enabled && summary_hook_write
    token_load || true
    [ -n "${TOKEN:-}" ] || return 0
    VER_TTL=0
    digest_fetch || rc=$?
    if [ "$rc" -eq 0 ]; then ok=1
    elif [ "$rc" -ne 2 ] && ! gh_limited >/dev/null; then
        for id in "${PRODUCTS[@]}"; do prod_installed "$id" && ids+=("$id"); done
        [ "${#ids[@]}" -gt 0 ] && versions_fetch "${ids[@]}" >/dev/null 2>&1
        self_fetch_versions >/dev/null 2>&1
        if v=$(VER_TTL=600 ver_cache_read "$SELF_ID" main) && [ -n "$v" ]; then ok=1; fi
    fi
    if [ "$ok" = 1 ]; then UI_SVED=$(date +%H:%M)
    else prev=$(sed -n 's/^sved=//p' "$SUM_FILE" 2>/dev/null) || prev=""; UI_SVED="${prev%%$'\n'*}"; UI_SVED="${UI_SVED:-—}"; fi
    ui_model_load
    mkdir -p "$(dirname "$SUM_FILE")" 2>/dev/null || return 1
    tmp="$SUM_FILE.tmp"
    {
        printf 'sved=%s\nninst=%s\nhost=%s\n' "$UI_SVED" "$UD_NINST" "$UD_HOST"
        for n in ${UD_NEWS[@]+"${UD_NEWS[@]}"}; do printf 'news=%s\n' "$n"; done
        for p in ${UD_PROB[@]+"${UD_PROB[@]:${UD_OSUPN:-0}}"}; do
            [ -n "${SHIELD_PROBS[0]:-}" ] && [ "$p" = "${SHIELD_PROBS[0]}" ] && continue
            printf 'prob=%s\n' "$p"
        done
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$SUM_FILE"
    return 0
}
# ui_emit_inline — те же строки, но просто вниз по экрану: сводка печатается
# перед приглашением командной строки, а не поверх окна.
ui_emit_inline() {  # ui_emit_inline [noeol] — noeol: последняя строка без перевода
    local out="" row seg tok txt sel s col k i=0 n="${#UI_ROWS[@]}"
    for row in "${UI_ROWS[@]}"; do
        i=$(( i + 1 ))
        col=0
        while [ -n "$row" ]; do
            seg="${row%%"$UI_RS"*}"; row="${row#*"$UI_RS"}"
            tok="${seg%%"$UI_US"*}"; txt="${seg#*"$UI_US"}"
            [ -n "$txt" ] || continue
            [ "$UI_ASCII" = 1 ] && { ui_ascii "$txt"; txt="$UI_P"; }
            sel=0; case "$tok" in *+sel) sel=1; tok="${tok%+sel}" ;; esac
            if [ "$tok" = grad ] && [ "$UI_GRADN" -gt 0 ]; then
                for ((k = 0; k < ${#txt}; k++)); do out+="${UI_GRAD[$(( col + k < UI_GRADN ? col + k : UI_GRADN - 1 ))]}${txt:k:1}"; done
            else
                if [ "$sel" = 1 ]; then s="${UI_SGRSEL[$tok]:-}"; else s="${UI_SGR[$tok]:-}"; fi
                out+="$s$txt"
            fi
            col=$(( col + ${#txt} ))
        done
        if [ "${1:-}" = noeol ] && [ "$i" -eq "$n" ]; then out+=$'\033[0m'; else out+=$'\033[0m\n'; fi
    done
    printf '%s' "$out"
}
# --motd: сводка из записанного файла, без сети; ширина и цвет — терминала.
# ── статистика защиты в сводке при входе (sh-a/b/c макета) ─────────────
# Числа готовит снимок (stats/summary); здесь — только вычесть отметку
# прошлого показа (stats/seen) и разложить по строкам. Нет сводки, уровень 0
# (nft не умеет счётчиков), защита не работает или снята — строк нет.
# Сканеры выкл — блок «Б»: сводка в рамке с отсчётом и замечание в значке.
_shield_nf() {  # число с разделителем тысяч: ru — пробел, en — запятая
    local n="$1" r="" sep=" "
    [ "${LANG_CODE:-ru}" = en ] && sep=","
    while [ "${#n}" -gt 3 ]; do r="${sep}${n: -3}${r}"; n="${n:0:$(( ${#n} - 3 ))}"; done
    printf '%s%s' "$n" "$r"
}
_shield_pl() {  # _shield_pl <n> <один> <два> <пять> <one> <many> → UI_TX «1 284 попытки»
    ui_plural "$@"; UI_TX="$(_shield_nf "$1")${UI_TX#"$1"}"
}
_shield_when() {  # _shield_when <время> [d] → «02.11 18:40»; en — «2 Nov 18:40» (d — без времени)
    local d m
    local -a M=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    if [ "${LANG_CODE:-ru}" != en ]; then printf '%(%d.%m %H:%M)T' "$1"; return 0; fi
    printf -v d '%(%d)T' "$1"; printf -v m '%(%m)T' "$1"
    printf '%s %s' "$(( 10#$d ))" "${M[$(( 10#$m - 1 ))]}"
    [ "${2:-}" = d ] || printf ' %(%H:%M)T' "$1"
}
_shield_sum_load() {
    local f se l k v at upto cin cfw csr
    UD_SH=""; UD_SHOFF=""; UD_SH_OLD=""
    _shield_stats_paths
    f="$SHIELD_STATS/summary"; se="$SHIELD_STATS/seen"
    [ -r "$f" ] && [ ! -L "$SHIELD_STATS" ] || return 0
    case "${SHS_ST:-none}" in ok|off) ;; *) return 0 ;; esac
    for k in snap lvl started tin tfw tsr d24_in d24_fw d24_sr spike_h spike_x10 spike_n away_ref away_n; do printf -v "UD_SS_$k" '%s' 0; done
    UD_SS_t24_1=""; UD_SS_t24_2=""; UD_SS_t24_3=""
    while IFS= read -r l || [ -n "$l" ]; do
        k="${l%%=*}"; v="${l#*=}"
        case "$k" in
            snap|lvl|started|tin|tfw|tsr|d24_in|d24_fw|d24_sr|spike_h|spike_x10|spike_n|away_ref|away_n)
                case "$v" in ''|*[!0-9]*) v=0 ;; esac
                [ "${#v}" -le 15 ] || v=0
                printf -v "UD_SS_$k" '%s' "$((10#$v))" ;;
            t24_1|t24_2|t24_3) printf -v "UD_SS_$k" '%s' "$v" ;;
        esac
    done < "$f"
    [ "$UD_SS_lvl" -ge 1 ] || return 0
    at=$(_shield_num "$se" at); upto=$(_shield_num "$se" upto)
    cin=$(_shield_num "$se" cin); cfw=$(_shield_num "$se" cfw); csr=$(_shield_num "$se" csr)
    # Отметка старше начала статистики (обнулили) — как не было.
    if [ "$upto" -lt "$UD_SS_started" ]; then at=0; upto=0; cin=0; cfw=0; csr=0; fi
    [ "$at" -gt 0 ] || at="$UD_SS_started"
    UD_SH_AT="$at"
    UD_SH_IN=$(( UD_SS_tin - cin )); [ "$UD_SH_IN" -ge 0 ] || UD_SH_IN=0
    UD_SH_OUT=$(( UD_SS_tfw + UD_SS_tsr - cfw - csr )); [ "$UD_SH_OUT" -ge 0 ] || UD_SH_OUT=0
    if [ "$UD_SS_snap" -le "$upto" ]; then UD_SH_AD=0; else UD_SH_AD="$UD_SS_away_n"; fi
    # Снимок раз в час. Старше 3 ч — снимки встали (ошибка, нет места,
    # stats/ ссылкой…): числа — на время снимка, «за сутки» их не выдавать.
    if [ "$UD_SS_snap" -gt 0 ] && [ $(( $(_shield_now) - UD_SS_snap )) -gt 10800 ]; then UD_SH_OLD="$UD_SS_snap"; fi
    if [ "${SHS_SCAN:-0}" = 1 ]; then UD_SH=A; else UD_SH=B; UD_SHOFF=1; fi
    return 0
}
# Отметка показа — только при входе root по SSH (скрипт входа ставит
# GOINST_SUMMARY_SHOWN), не от ручного goinstall --motd.
_shield_sum_seen() {
    [ -n "${UD_SH:-}" ] && [ -n "${GOINST_SUMMARY_SHOWN:-}" ] || return 0
    [ "${EUID:-1}" = 0 ] || [ -n "${GOINST_TEST:-}" ] || return 0
    [ -d "$SHIELD_STATS" ] && [ ! -L "$SHIELD_STATS" ] || return 0
    _shield_set "$SHIELD_STATS/seen" "at=$(_shield_now)" "upto=${UD_SS_snap}" "cin=${UD_SS_tin}" "cfw=${UD_SS_tfw}" "csr=${UD_SS_tsr}"
}
# Строки «Вход» и «Выход» (awayLines макета).
_shield_sum_away() {  # _shield_sum_away <отступ> <сканеры 0|1>
    local ind="$1" on="$2" n=0 inum itok gi gt il ol onum
    [ "$UI_C" -lt 60 ] && n=1
    _shield_pl "$UD_SH_IN" попытка попытки попыток attempt attempts; inum="$UI_TX"
    if [ "$UD_SS_lvl" -ge 2 ]; then _shield_pl "$UD_SH_AD" адрес адреса адресов address addresses; inum+=" · ${UI_TX}"; fi
    _shield_pl "$UD_SH_OUT" соединение соединения соединений connection connections; onum="$UI_TX"
    ut " к сетям ВК" " to VK networks"; onum+="$UI_TX"
    if [ "$on" = 1 ]; then gi="✓"; gt=ok; itok=title; ut "Вход · сканеры остановлены" "In · scanners stopped"
    else gi="!"; gt=warn; itok=warn; ut "Вход · выкл · только считает" "In · off · counting only"; fi
    il="$UI_TX"
    if [ "$n" = 0 ]; then
        UI_BX+=("${gt}${UI_US}${ind}${gi}${UI_RS}text${UI_US} ${il}: ${UI_RS}${itok}${UI_US}${inum}${UI_RS}")
        if [ "${SHS_VK:-0}" = 1 ]; then
            ut "Выход · утечка IP предотвращена" "Out · IP leak prevented"
            UI_BX+=("ok${UI_US}${ind}✓${UI_RS}text${UI_US} ${UI_TX}: ${UI_RS}title${UI_US}${onum}${UI_RS}")
        else
            ut "Выход · выкл · защита от утечки IP не работает" "Out · off · IP leak protection is not working"
            UI_BX+=("warn${UI_US}${ind}!${UI_RS}warn${UI_US} ${UI_TX}${UI_RS}")
        fi
    else
        UI_BX+=("${gt}${UI_US}${ind}${gi}${UI_RS}text${UI_US} ${il}:${UI_RS}")
        UI_BX+=("${itok}${UI_US}${ind}  ${inum}${UI_RS}")
        if [ "${SHS_VK:-0}" = 1 ]; then
            ut "Выход · утечка IP предотвращена" "Out · IP leak prevented"
            UI_BX+=("ok${UI_US}${ind}✓${UI_RS}text${UI_US} ${UI_TX}:${UI_RS}")
            UI_BX+=("title${UI_US}${ind}  ${onum}${UI_RS}")
        else
            ut "Выход · выкл ·" "Out · off ·"; UI_BX+=("warn${UI_US}${ind}!${UI_RS}warn${UI_US} ${UI_TX}${UI_RS}")
            ut "защита от утечки IP не работает" "IP leak protection is not working"; UI_BX+=("warn${UI_US}${ind}  ${UI_TX}${UI_RS}")
        fi
    fi
}
# Снимки встали — строка «данные от …» (REVIEW-6 №4); 0 — снимки свежие.
_shield_sum_old() {  # _shield_sum_old <отступ>
    [ -n "${UD_SH_OLD:-}" ] || return 1
    if [ "$UI_C" -lt 60 ]; then ut " данные от $(_shield_when "$UD_SH_OLD")" " data as of $(_shield_when "$UD_SH_OLD")"
    else ut " Данные от $(_shield_when "$UD_SH_OLD") — статистика не обновляется" " Data as of $(_shield_when "$UD_SH_OLD") — statistics are not updating"; fi
    UI_BX+=("warn${UI_US}${1}!${UI_RS}warn${UI_US}${UI_TX}${UI_RS}")
}
# Блок «А» (сканеры вкл) или «Б» (выкл) — в рамку сводки, строки UI_BX.
_shield_sum_box() {
    local n=0 x w i e asn nm att ad tok ind pl
    [ "$UI_C" -lt 60 ] && n=1
    if [ "$UD_SH" = B ]; then
        if [ "$n" = 0 ]; then
            ut " Защита от сканеров: " " Scanner protection: "; x="$UI_TX"; ut "выкл" "off"; w="$UI_TX"
            ut " · сервер не блокирует, только считает" " · the server does not block, only counts"
            UI_BX+=("warn${UI_US} !${UI_RS}name${UI_US}${x}${UI_RS}warn${UI_US}${w}${UI_RS}muted${UI_US}${UI_TX}${UI_RS}")
            ut "   Пока вас не было (с $(_shield_when "$UD_SH_AT")):" "   While you were away (since $(_shield_when "$UD_SH_AT")):"
            UI_BX+=("text${UI_US}${UI_TX}${UI_RS}")
            _shield_sum_away "     " 0
            _shield_sum_old "   "
            ut "   Рекомендуем включить: " "   Recommended: "; x="$UI_TX"; ut " Защита" " Scanner protection"; w="$UI_TX"; ut " Включить защиту" " Turn protection on"
            UI_BX+=("text${UI_US}${x}${UI_RS}key${UI_US}goinstall${UI_RS}muted${UI_US} → ${UI_RS}key${UI_US}s${UI_RS}text${UI_US}${w}${UI_RS}muted${UI_US} → ${UI_RS}key${UI_US}1${UI_RS}text${UI_US}${UI_TX}${UI_RS}")
        else
            ut " Защита: " " Protection: "; x="$UI_TX"; ut "выкл" "off"; w="$UI_TX"
            ut " · с $(_shield_when "$UD_SH_AT"):" " · since $(_shield_when "$UD_SH_AT" d):"
            UI_BX+=("warn${UI_US}!${UI_RS}name${UI_US}${x}${UI_RS}warn${UI_US}${w}${UI_RS}muted${UI_US}${UI_TX}${UI_RS}")
            _shield_sum_away "  " 0
            _shield_sum_old "  "
            ut "  включить: " "  turn on: "; x="$UI_TX"; ut " Защита" " → 1"
            UI_BX+=("text${UI_US}${x}${UI_RS}key${UI_US}goinstall${UI_RS}muted${UI_US} → ${UI_RS}key${UI_US}s${UI_RS}text${UI_US}${UI_TX}${UI_RS}")
        fi
        return 0
    fi
    if [ "$n" = 0 ]; then
        ut " Защита от сканеров" " Scanner protection"; x="$UI_TX"
        ut " · пока вас не было (с $(_shield_when "$UD_SH_AT")):" " · while you were away (since $(_shield_when "$UD_SH_AT")):"
        UI_BX+=("ok${UI_US} ✓${UI_RS}name${UI_US}${x}${UI_RS}muted${UI_US}${UI_TX}${UI_RS}")
        ind="   "
    else
        ut " Защита" " Protection"; x="$UI_TX"; ut " · с $(_shield_when "$UD_SH_AT"):" " · since $(_shield_when "$UD_SH_AT"):"
        UI_BX+=("ok${UI_US}✓${UI_RS}name${UI_US}${x}${UI_RS}muted${UI_US}${UI_TX}${UI_RS}")
        ind="  "
    fi
    _shield_sum_away "$ind" 1
    # Старые данные — без всплеска и топа «за сутки».
    _shield_sum_old "$ind" && return 0
    e=""
    if [ "$UD_SS_spike_x10" -gt 0 ] && [ "$UD_SS_spike_h" -gt 0 ]; then
        e=1
        x="$(( UD_SS_spike_x10 / 10 ))$(bi , .)$(( UD_SS_spike_x10 % 10 ))"
        printf -v w '%(%H:%M)T' "$UD_SS_spike_h"
        if [ "$n" = 0 ]; then ut " Всплеск в ${w}: попыток в ${x} раза больше обычного ($(_shield_nf "$UD_SS_spike_n") за час)" " Spike at ${w}: ${x}× the usual attempts ($(_shield_nf "$UD_SS_spike_n") in an hour)"
        else ut " всплеск в ${w}: ×${x} к обычному" " spike at ${w}: ×${x} the usual"; fi
        UI_BX+=("warn${UI_US}${ind}▲${UI_RS}text${UI_US}${UI_TX}${UI_RS}")
        [ "$n" = 1 ] && return 0
    fi
    # Топ сетей — только с попытками по адресам (уровень 3).
    [ "$UD_SS_lvl" -ge 3 ] && [ -n "$UD_SS_t24_1" ] || return 0
    ut "предположительно, по названию сети" "presumably, by network name"; pl="$UI_TX"
    if [ "$n" = 1 ]; then
        IFS='|' read -r asn nm att ad <<<"$UD_SS_t24_1"
        case "$asn" in ''|0|*[!0-9]*) asn="—" ;; *) asn="AS${asn}" ;; esac
        ut "  чаще всего: " "  most active: "; x="$UI_TX"; tok=name
        [ -n "$nm" ] || { ut "без подписи в списке" "no label in the list"; nm="$UI_TX"; tok=muted; }
        UI_BX+=("muted${UI_US}${x}${UI_RS}text${UI_US}${asn} ${UI_RS}${tok}${UI_US}${nm}${UI_RS}")
        UI_BX+=("muted${UI_US}  (${pl})${UI_RS}")
        return 0
    fi
    ut "   Чаще всего за сутки" "   Most active over 24 h"
    UI_BX+=("text${UI_US}${UI_TX}${UI_RS}muted${UI_US} (${pl}):${UI_RS}")
    for i in 1 2 3; do
        [ "$i" = 3 ] && [ -n "$e" ] && break
        x="UD_SS_t24_$i"; [ -n "${!x}" ] || break
        IFS='|' read -r asn nm att ad <<<"${!x}"
        case "$asn" in ''|0|*[!0-9]*) asn="—" ;; *) asn="AS${asn}" ;; esac
        case "$att" in ''|*[!0-9]*) att=0 ;; esac; case "$ad" in ''|*[!0-9]*) ad=0 ;; esac
        tok=name; [ -n "$nm" ] || { ut "без подписи в списке" "no label in the list"; nm="$UI_TX"; tok=muted; }
        ui_padr "$asn" 9; x="$UI_P"; ui_padr "$nm" 40; nm="$UI_P"
        printf -v w '%6s' "$(_shield_nf "$att")"
        UI_BX+=("text${UI_US}     ${x}${UI_RS}${tok}${UI_US}${nm}${UI_RS}text${UI_US}${w} · $(_shield_nf "$ad")${UI_RS}")
    done
}
# Тихая форма (sh-c): одна строка за сутки.
_shield_sum_quiet() {
    local n=0 a b
    [ "$UI_C" -lt 60 ] && n=1
    UI_SEG=""; _s ok "✓ "; ut "Защита: вкл" "Protection: on"; _s text "$UI_TX"
    if [ -n "${UD_SH_OLD:-}" ]; then
        if [ "$n" = 1 ]; then ut " · данные от $(_shield_when "$UD_SH_OLD")" " · data as of $(_shield_when "$UD_SH_OLD")"
        else ut " · статистика не обновлялась с $(_shield_when "$UD_SH_OLD")" " · statistics not updated since $(_shield_when "$UD_SH_OLD")"; fi
    elif [ "$n" = 1 ]; then
        a="$(_shield_nf "$UD_SS_d24_in")"
        if [ "${SHS_VK:-0}" = 1 ]; then b="$(_shield_nf $(( UD_SS_d24_fw + UD_SS_d24_sr )))"; else ut "выкл" "off"; b="$UI_TX"; fi
        ut " · сутки: вход ${a} · выход ${b}" " · 24 h: in ${a} · out ${b}"
    else
        _shield_pl "$UD_SS_d24_in" попытка попытки попыток attempt attempts; a="$UI_TX"
        if [ "${SHS_VK:-0}" = 1 ]; then _shield_pl $(( UD_SS_d24_fw + UD_SS_d24_sr )) соединение соединения соединений connection connections; ut "${UI_TX} к ВК" "${UI_TX} to VK"; b="$UI_TX"
        else ut "выкл" "off"; b="$UI_TX"; fi
        ut " · за сутки: вход ${a} · выход ${b}" " · over 24 h: in ${a} · out ${b}"
    fi
    _s muted "$UI_TX"
    ui_body "$UI_SEG"
}
summary_print() {
    local l k v
    [ -r "$SUM_FILE" ] || return 0
    UD_NEWS=(); UD_PROB=(); UD_SVED=""; UD_NINST=0; UD_HOST=""
    while IFS= read -r l; do
        k="${l%%=*}"; v="${l#*=}"
        case "$k" in
            sved) UD_SVED="$v" ;; ninst) UD_NINST="$v" ;; host) UD_HOST="$v" ;;
            news) UD_NEWS+=("$v") ;; prob) UD_PROB+=("$v") ;;
        esac
    done < "$SUM_FILE"
    # Обновление Ubuntu — вживую из состояния: таймер пишет файл раз в 30 минут.
    # Защита от сканеров — из своих файлов (итог проверки таймера, дата
    # списка), без nft: вход не ждёт.
    osup_probs; shield_state; shield_probs; _shield_sum_load
    UD_PROB=(${OSUP_PROBS[@]+"${OSUP_PROBS[@]}"} ${SHIELD_PROBS[@]+"${SHIELD_PROBS[@]}"} ${UD_PROB[@]+"${UD_PROB[@]}"})
    ui_sysload
    ui_detect
    [ "$UI_C" = 40 ] && UI_C=46
    UI_R=0; UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_summary
    UI_ROWS=(); for l in "${UI_BODY[@]}"; do ui_fit "$l" "$UI_C"; UI_ROWS+=("$UI_FIT"); done
    ui_emit_inline
    _shield_sum_seen
    if [ "${#UD_NEWS[@]}" -gt 0 ] || [ "${#UD_PROB[@]}" -gt 0 ] || [ -n "${UD_SHOFF:-}" ]; then summary_countdown; return $?; fi
    return 0
}
# Отсчёт под сводкой (экран «Б» макета): Enter — открыть goinstall, любая
# другая клавиша — в консоль, через 5 секунд — тоже в консоль. Только когда
# в сводке есть что делать и только в терминале: вход не должен ждать там,
# где отвечать некому. rc 10 — открыть меню.
summary_countdown() {
    local total="${GOINST_COUNTDOWN_MS:-5000}" step=250 rem k n=0 w st="" _r
    case "$total" in ''|*[!0-9]*|0) total=5000 ;; esac
    if [ -z "${GOINST_COUNTDOWN_FORCE:-}" ]; then { [ -t 0 ] && [ -t 1 ]; } || return 0; fi
    # Уже что-то набрано (человек печатает команду, ssh с вводом из скрипта)
    # — отсчёта нет: он съел бы первую букву, а перевод строки открыл бы меню.
    if IFS= read -t 0 _r 2>/dev/null; then return 0; fi
    [ "$UI_C" -lt 60 ] && n=1
    # Не шире окна: перенесённая строка не стёрлась бы, и приглашение
    # оболочки встало бы под остатком отсчёта.
    w="$UI_C"; [ "${UI_COLS:-80}" -le "$w" ] && w=$(( UI_COLS - 1 ))
    UI_SEG=""; _s text "  "; _s key "Enter"
    if [ "$n" = 1 ]; then
        ut " — goinstall · другая клавиша — консоль" " — goinstall · other key — shell"
        # Строка макета — во всю ширину 46, а пишем на знак уже окна: в 46
        # она обрезалась «…консо…» (К5-15, стенд 03.11) — тогда короче.
        [ $(( 7 + $(str_len "$UI_TX") )) -le "$w" ] || ut " — goinstall · иначе — консоль" " — goinstall · else — shell"
    else ut " — открыть goinstall · любая другая клавиша — в консоль" " — open goinstall · any other key — shell"; fi
    _s muted "$UI_TX"; ui_fit "$UI_SEG" "$w"; UI_ROWS=("$UI_FIT"); ui_emit_inline
    st=$(stty -g 2>/dev/null) || st=""
    # Прервали Ctrl-C — стереть отсчёт, вернуть терминал и отдать консоль.
    trap '[ -n "$st" ] && stty "$st" 2>/dev/null; printf "\r\033[K\033[1A\033[K"; exit 0' INT
    rem="$total"
    while [ "$rem" -gt 0 ]; do
        UI_SEG=""; _s text "  "; ui_bar $(( rem * 1000 / total )) $(( n ? 20 : 24 )) cursor; UI_SEG+="$UI_BAR"
        ut " с" " s"; _s muted "  $(( (rem + 999) / 1000 ))$UI_TX"
        printf '\r'; ui_fit "$UI_SEG" "$w"; UI_ROWS=("$UI_FIT"); ui_emit_inline noeol; printf '\033[K'
        if IFS= read -rsn1 -t 0.25 k; then
            # Стрелка или функциональная клавиша — это несколько байт: хвост
            # «[A» иначе ушёл бы в оболочку командой.
            if [ "$k" = $'\033' ]; then while IFS= read -rsn1 -t 0.02 _r; do :; done; fi
            printf '\r\033[K\033[1A\033[K'; trap - INT
            [ -n "$st" ] && stty "$st" 2>/dev/null
            case "$k" in ''|$'\r') return 10 ;; esac
            return 0
        fi
        rem=$(( rem - step ))
    done
    printf '\r\033[K\033[1A\033[K'; trap - INT
    [ -n "$st" ] && stty "$st" 2>/dev/null
    return 0
}

summary_enabled() { [ "$(cat "$SUM_CHOICE" 2>/dev/null)" = yes ]; }

# Скрипт входа. Ловушка на Ctrl-C — в оболочке входа: без неё Ctrl-C во
# время сводки обрывал и остаток профиля (PS1 и прочее не выставлялись).
summary_hook_text() {
    cat <<'HOOK'
# goInstaller: сводка при входе. Выключить — goinstall --summary off.
if [ -t 0 ] && [ -t 1 ] && [ "$(id -u)" = 0 ] && [ -z "${GOINST_SUMMARY_SHOWN:-}" ] && [ ! -e "$HOME/.hushlogin" ] && command -v goinstall >/dev/null 2>&1; then
    export GOINST_SUMMARY_SHOWN=1
    trap : INT
    goinstall --motd 2>/dev/null
    trap - INT
fi
HOOK
}
# Записать скрипт входа, если он не такой, как у этой версии: так серверы,
# включившие сводку раньше, получают правки скрипта с первым же опросом.
summary_hook_write() {
    local want
    want=$(summary_hook_text)
    [ "$(cat "$SUM_HOOK" 2>/dev/null)" = "$want" ] && return 0
    mkdir -p "$(dirname "$SUM_HOOK")" 2>/dev/null || return 1
    printf '%s\n' "$want" > "$SUM_HOOK" 2>/dev/null || return 1
    chmod 644 "$SUM_HOOK" 2>/dev/null || true
    return 0
}
# Включить: таймер раз в 30 минут со сдвигом до 10, скрипт входа — только
# для root, только в терминале и не для ~/.hushlogin.
summary_enable() {
    mkdir -p "$SUM_UNIT_DIR" "$(dirname "$SUM_HOOK")" "$(dirname "$SUM_CHOICE")" 2>/dev/null || return 1
    cat > "$SUM_UNIT_DIR/goinstall-watch.service" <<UNIT
[Unit]
Description=goInstaller: опрос обновлений для сводки при входе
After=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=${GOINST_BIN} --watch
UNIT
    cat > "$SUM_UNIT_DIR/goinstall-watch.timer" <<UNIT
[Unit]
Description=goInstaller: опрос обновлений раз в 30 минут

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    summary_hook_write
    chmod 644 "$SUM_HOOK" "$SUM_UNIT_DIR/goinstall-watch.service" "$SUM_UNIT_DIR/goinstall-watch.timer" 2>/dev/null
    printf 'yes\n' > "$SUM_CHOICE"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now goinstall-watch.timer >/dev/null 2>&1 || true
        systemctl start --no-block goinstall-watch.service >/dev/null 2>&1 || true
    fi
    return 0
}
summary_disable() {
    if command -v systemctl >/dev/null 2>&1; then systemctl disable --now goinstall-watch.timer >/dev/null 2>&1 || true; fi
    rm -f "$SUM_UNIT_DIR/goinstall-watch.service" "$SUM_UNIT_DIR/goinstall-watch.timer" "$SUM_HOOK" "$SUM_FILE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    mkdir -p "$(dirname "$SUM_CHOICE")" 2>/dev/null && printf 'no\n' > "$SUM_CHOICE"
    return 0
}
# Вопрос о сводке — один раз, при первом запуске меню.
ui_scr_sumask() {
    local l
    UI_CUR="$1"
    UI_BODY=(); UI_INFO=""; UI_KEYS=""
    ui_main_title; ui_hdr "$UI_MT" ""; ui_body ""
    ut "Показывать сводку при входе на сервер?" "Show a summary when you log in to the server?"; ui_body "title${UI_US}  ${UI_TX}${UI_RS}"; ui_body ""
    ut "Вошли по SSH — и сразу видно, что вышли обновления, появились новые продукты или скоро истекает сертификат. Для этого goInstaller поставит таймер: раз в 30 минут он тихо спрашивает GitHub. Вход сети не ждёт — сводка берётся из записанного." "Log in over SSH and see right away that updates are out, new products appeared or a certificate is about to expire. goInstaller installs a timer for it: every 30 minutes it quietly asks GitHub. Logging in never waits for the network — the summary comes from saved data."
    ui_wrap "$UI_TX" $(( UI_C - 4 )); for l in "${UI_WRAP[@]}"; do ui_body "muted${UI_US}  ${l}${UI_RS}"; done
    ui_body ""
    ut "Выключить потом: goinstall --summary off" "Turn off later: goinstall --summary off"; ui_body "muted${UI_US}  ${UI_TX}${UI_RS}"; ui_body ""
    ui_items_clear; ut "Да" "Yes"; ui_item 1 "$UI_TX" sumyes; ut "Нет" "No"; ui_item 2 "$UI_TX" sumno
    ui_choicerows "$UI_CUR"
    local a; ut "да" "yes"; a="$UI_TX"; ut "нет" "no"; ui_keys_fit "1|$a|" "2|$UI_TX|"
}

# Новый интерфейс — когда есть терминал на входе и выходе и TERM не dumb.
# Иначе прежний нумерованный список: запуск из скрипта, TERM=dumb,
# GOINST_PLAIN_MENU=1.
ui_can_run() {
    [ -z "${GOINST_PLAIN_MENU:-}" ] && [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]
}

main() {
    case "${1:-}" in
        -v|--version) echo "goInstaller ${GOINST_VERSION}"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        # Сводка при входе: из записанного файла, без сети и без проверок —
        # вход по SSH не должен ждать ничего.
        --motd)
            summary_print
            if [ "$?" -eq 10 ] && [ -x "$GOINST_BIN" ]; then
                # Enter на отсчёте — меню. Скрипт входа глушит stderr
                # (2>/dev/null); возвращаем его терминалу, иначе ошибки
                # установщиков пропадут.
                if { : >/dev/tty; } 2>/dev/null; then exec 2>/dev/tty; fi
                ui_flush_input
                exec "$GOINST_BIN"
            fi
            exit 0 ;;
        # Сводка версий для клуба — её собирает GitHub Actions, не root и не
        # на сервере: ключ из GH_TOKEN, вывод в stdout.
        --digest) token_load || true; digest_build; exit $? ;;
        # Исполнитель обновления Ubuntu: его зовёт служба после каждой
        # загрузки, без терминала и без сети GitHub — только свой шаг.
        # Прерывание, записанное в состояние, — не падение службы: с кодом 1
        # она осталась бы в systemctl --failed без файла юнита (reset-failed
        # из самой службы, пока она идёт, не действует). Упал сам исполнитель
        # — код не 0, это видит osup_alive, отметку снимет уборка снаружи.
        --os-upgrade-run) os_detect; osup_run; rc=$?
            [ "$rc" -ne 0 ] && osup_load && [ "${OSU[status]:-}" = failed ] && rc=0
            exit "$rc" ;;
        # Ход обновления при входе по SSH (временный скрипт входа): из
        # состояния, без сети и без проверок, как --motd.
        --os-upgrade) if [ "${2:-}" = status ] && [ "${3:-}" = --short ]; then osup_short; exit 0; fi ;;
    esac

    # Язык — первым экраном, до любых проверок: всё дальнейшее, включая
    # отказы, человек должен прочитать на своём языке. Спрашиваем только там,
    # где с ним говорят, — в меню и при установке. Справочные команды берут
    # запомненный язык, чтобы не ломать запуск из скриптов.
    case "${1:-}" in
        ''|--install)
            reattach_tty
            lang_startup || exit 1 ;;
    esac

    if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        die "$(bi "Нужен bash 4.0+ (найден ${BASH_VERSION:-?})" "bash 4.0+ is required (found ${BASH_VERSION:-?})")"
    fi
    os_detect
    os_gate_common
    # GOINST_TEST=1 — тесты: без root, без ss (фикстура), без установки curl.
    if [ -z "${GOINST_TEST:-}" ]; then
    [ "$(id -u)" -eq 0 ] || die "$(bi "Запустите от root: sudo bash …" "Run as root: sudo bash …")"
    command -v ss >/dev/null 2>&1 || die "$(bi "Нет ss (пакет iproute2) — без него порты не проверить." "ss is missing (package iproute2) — ports cannot be checked without it.")"
    command -v curl >/dev/null 2>&1 || {
        say "$(bi "Ставлю curl…" "Installing curl…")"
        DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=600 update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=600 install --no-install-recommends curl ca-certificates >/dev/null 2>&1 \
            || die "$(bi "Не удалось поставить curl." "Could not install curl.")"
    }
    fi

    lang_persist

    # Ключ читаем ДО разбора команды. Раньше его подхватывал только путь
    # меню, и `--versions` на машине с сохранённым ключом честно отвечал
    # «нет ключа»: ключ лежал рядом, но никто его не открывал.
    token_load || true

    case "${1:-}" in
        --list) list_products; exit 0 ;;
        --ports) show_ports; exit 0 ;;
        --versions) show_versions; exit 0 ;;
        --self-update) self_update "${2:-}"; exit $? ;;
        --watch) os_detect; shield_sync; summary_watch; exit 0 ;;
        --net) reattach_tty; net_mtu_offer force; exit $? ;;
        --components) shift; reattach_tty; comp_cli "$@"; exit $? ;;
        # Защита от сканеров: tick, status, check, update — и из таймера, без
        # терминала; терминал подключаем только туда, где может быть вопрос.
        --shield) shift; case "${1:-status}" in on|off|remove|vk) reattach_tty ;; esac
                  [ "${1:-}:${2:-}" = stats:reset ] && reattach_tty
                  shield_cli "$@"; exit $? ;;
        --uninstall) shift; reattach_tty; goinst_uninstall "$@"; exit $? ;;
        --os-upgrade) shift; reattach_tty; osup_cli "$@"; exit $? ;;
        --summary)
            case "${2:-}" in
                on)  summary_enable && ok "$(bi "Сводка при входе включена: опрос раз в 30 минут." "Login summary is on: polling every 30 minutes.")"; exit 0 ;;
                off) summary_disable; ok "$(bi "Сводка при входе выключена, таймер снят." "Login summary is off, the timer is removed.")"; exit 0 ;;
                *) usage; exit 64 ;;
            esac ;;
        --key)
            case "${2:-}" in
                forget) token_forget; ok "$(bi "Сохранённый ключ удалён." "The saved key is removed.")"; exit 0 ;;
                check)  token_load || { err "$(bi "Ключа нет." "No key.")"; exit 1; }
                        token_check
                        case "$TOKEN_STATUS" in
                            ok)     ok "$(bi "Ключ читает все репозитории продуктов." "The key reads every product repository.")"; exit 0 ;;
                            denied) warn "$(bi "Ключ не открывает: ${TOKEN_DENIED}" "The key does not open: ${TOKEN_DENIED}")"; exit 2 ;;
                            nonet)  warn "$(bi "До GitHub не достучаться." "GitHub is unreachable.")"
                                    [ -n "${TOKEN_NETRC:-}" ] && say "$(bi "Причина" "Cause"): $(gh_net_reason "$TOKEN_NETRC"). $(bi "Пробовал ${GH_TRIES} раза на каждый запрос, ожидание до ${GH_MT} с." "Tried ${GH_TRIES} times per request, waiting up to ${GH_MT} s.")"
                                    exit 3 ;;
                            limited) warn "$(bi "Исчерпан общий лимит запросов GitHub, снова заработает к $(gh_reset_text). Ключ не виноват." "The shared GitHub request limit is used up until $(gh_reset_text). The key is not at fault.")"; exit 4 ;;
                            *)      err "$(bi "GitHub этот ключ не принимает." "GitHub rejects this key.")"; exit 1 ;;
                        esac ;;
                ''|set)  TOKEN=""; TOKEN_FROM=""; token_prompt; exit $? ;;
                *) usage; exit 64 ;;
            esac ;;
        --check)
            valid_id "${2:-}" || { usage; exit 64; }
            mode_arg "$2" "${3:-}" || exit 64
            if [ -n "${3:-}" ]; then MODE="$3"; else mode_resolve "$2" || MODE=pro; fi
            preflight "$2" "$MODE"; exit $? ;;
        --install)
            valid_id "${2:-}" || { usage; exit 64; }
            # У продукта без режимов третье слово — ветка:
            # `goinstall --install gokaskad dev`. Иначе dev стал бы «режимом».
            # Имя ветки (main, dev…) — ветка, прочее остаётся прежним «режимом»
            # без смысла: `--install gokaskad pro` работал и раньше. Сверка
            # ветки — после опроса GitHub: в кеше сервера мог остаться список
            # без dev, а запасной `main dev` есть не у всех.
            local im="${3:-}" ir="${4:-}"
            if ! prod_has_modes "$2" && [ -n "$im" ] && [ -z "$ir" ]; then
                if [[ "$im" =~ ^(main|master|dev|develop)$ ]] || ref_arg_known "$2" "$im"; then ir="$im"; im=""; fi
            fi
            mode_arg "$2" "$im" || exit 64
            osup_busy_refuse && exit 1
            reattach_tty; net_mtu_offer; self_install; shield_offer
            versions_fetch "$2"
            ref_arg "$2" "$ir" || exit 64
            REF="$ir"
            free_takeover_note "$2"
            if [ -n "$im" ]; then MODE="$im"
            elif ! mode_resolve "$2"; then ask_mode "$2" || exit 1; fi
            [ -n "$REF" ] || ask_ref "$2" || exit 1
            preflight "$2" "$MODE"; local rc=$?
            if [ "$rc" -eq 1 ] && [ -z "${GOINST_FORCE:-}" ]; then exit 1; fi
            run_product_installer "$2"; rc=$?
            installer_postcheck "$2" "${REF:-$(prod_ref "$2")}" "$rc" || true
            shield_postcheck "$2"
            # Установщик вышел с 0, а продукта нет или на месте остался
            # бесплатный вариант — для скриптов это отказ, а не успех: код 1.
            # Человек просил pro, а pro нет. Код ≠0 установщика уходит как есть.
            [ "$rc" -eq 0 ] && case "${PC_WHY:-}" in none|free) rc=1 ;; esac
            exit "$rc" ;;
        '') ;;
        *) usage; exit 64 ;;
    esac

    reattach_tty
    # До первого обращения к GitHub: узкий путь рвёт TLS через раз.
    NET_CHANGED=""
    net_mtu_offer
    self_install
    # Защита от сканеров — сразу после языка и установки себя, до ключа и
    # продуктов (решение заказчика 02.11.2026). Один раз: отказ запоминается.
    shield_offer
    # «Аркада»: ключ проверяется и версии спрашиваются в фоне, под заставкой;
    # меню открывается сразу, без ожидания сети.
    if ui_can_run; then
        # Размер пакета меняли или откатывали — итог сначала прочитать: экран
        # «Аркады» сразу его затирал. Ничего не меняли — старт не тормозим.
        if [ -n "${NET_CHANGED:-}" ] || [ -n "${SHIELD_SAID:-}" ]; then echo -ne "  $(bi "Нажмите Enter, чтобы открыть меню" "Press Enter to open the menu") " >&2; read -r || true; fi
        token_load || true
        ui_main
        if [ -n "${UI_UNINSTALL:-}" ]; then
            goinst_remove "$UI_UNINSTALL" && goinst_remove_done "$UI_UNINSTALL"
        fi
        return 0
    fi
    # Ключ проверяется до всего остального: без него нечего ни опрашивать,
    # ни скачивать, и узнать об этом лучше сразу, а не в середине установки.
    token_startup
    self_fetch_versions
    # Опрос версий — до первого экрана: пункт «обновить» без номера версии
    # в ветке предлагает обновляться вслепую. Без ключа и без сети опрос
    # молча пропускается, меню от этого не задерживается.
    versions_fetch
    main_menu
}

# GOINST_SOURCE_ONLY=1 — тесты подключают файл ради функций, не запуская меню.
if [ -z "${GOINST_SOURCE_ONLY:-}" ]; then
    main "$@"
fi
