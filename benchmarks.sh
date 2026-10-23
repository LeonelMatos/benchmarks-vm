#!/bin/bash
# BENCHMARKS (v4)
# Trabalho realizado para a cadeira de Virtualização e Centro de Dados
#   Joana Moreira, Leonel Matos, Fernando Gomes
# 16/10/2026
#
# Benchmark de máquinas virtuais: CPU (sysbench), memória (RAMspeed+STREAM),
# disco (IOzone+fio) e, opcionalmente, rede (iperf3).
# Cada teste é repetido REPETICOES vezes; no fim mostra a média, o desvio padrão,
# o mínimo, o máximo, o tempo gasto e grava tudo em ficheiros.
# São automaticamente instalados os programas e packages na primeira run.
#
# Uso:
#   ./benchmark.sh                  corre todos os testes, menos o iperf3
#   ./benchmark.sh 192.168.1.50     corre também o iperf3 contra esse servidor
#   REPETICOES=1 ./benchmark.sh     muda uma definição só nesta run
#
# Requisitos:
#   Executar em ubuntu-server (26.04.1) (ou outro Debian) conectado à internet 
# para instalação dos packages necessários na primeira run.
#
# 
# Execução:
# O script instala o que faltar (precisa de sudo), descarrega e compila o STREAM e o RAMspeed/SMP
# (cria as pastas STREAM/ e ramspeed-smp/ no diretório atual). Corre imediatamente os testes
# com o número de REPETICOES. No fim apaga os ficheiros de teste, mesmo com Ctrl-C 
# para interromper os testes.
#
# É fortemente recomendado executar primeiro o script com 1 REPETICOES para instalar e fazer discovery
# do iperf3 server na rede, e confirmar se todos os testes correm como esperado.
#   REPETICOES=1 ./benchmark.sh
# Também é importante confirmar se a interface de rede está UP e ligada à LAN fora da VM.
#
# Configurar iperf3 server:
# iperf3 -s #iniciar server na porta 5201
#
# Resultados, na pasta resultados/:
#   benchmark_DATA.txt  resultado completo
#   benchmark_DATA.csv  resumo (média, desvio, mínimo, máximo) para tabela
#   benchmark_DATA.log  logs de instalação e execução
#
# TODO
# - parâmetro -v para mostrar as versões dos programas instalados (ou mostrar não instalados)
#   usar versao()

# --------------------------------------------------------------------------
# Definições
# --------------------------------------------------------------------------

# force local para linguagem de sistema, em inglês
export LC_ALL=C

REPETICOES="${REPETICOES:-10}"  #vezes que cada teste é repetido
# !Manter o número de repetições para o mínimo essencial, porque os testes podem
# levar quase 1h (ou 3h30 no Proxmox em USB)
TEMPO="${TEMPO:-30}"            #segundos de execução do sysbench e do fio
RAM_GB=8                        #GB usados pelo RAMspeed (precisa de RAM extra livre)
# !Não mudar tamanho do teste RAM, VMs têm 16GB alocadas, mas o meu portátil tem 8+16GB e
# o dual channel pode não funcionar bem em testes. Mais RAM não dá melhores resultados
RAM_PROCS=2                     #processos do RAMspeed
FIO_TAMANHO=1G                  #tamanho do ficheiro de teste do fixo
FIO_MOTOR=libaio                #motor de I/O do fio
IPERF_TEMPO=10                  #segundos de cada execução do iperf3

BASE="$(cd "$(dirname "$0")" && pwd)"
RAMSMP_DIR="$BASE/ramspeed-smp"
RAMSMP="$RAMSMP_DIR/ramsmp"
STREAM_DIR="$BASE/STREAM"
STREAM="$STREAM_DIR/stream"
IPERF_SERVER="$1"
N_CPUS="$(nproc 2>/dev/null || echo 1)"

OUT_DIR="$BASE/resultados"
mkdir -p "$OUT_DIR"
NOME="benchmark_$(date +%Y-%m-%d_%H-%M-%S)"
OUT="$OUT_DIR/$NOME.txt"
CSV="$OUT_DIR/$NOME.csv"
LOG="$OUT_DIR/$NOME.log"

IOZONE_FILE="$BASE/iozone_ficheiro" #ficheiros de teste. Ficam no disco que se mede
FIO_FILE="$BASE/fio_ficheiro"

#Sources do STREAM e do RAMspeed. O RAMspeed é verificado com SHA-256.
STREAM_URLS="https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c https://www.cs.virginia.edu/stream/FTP/Code/stream.c"
RAMSMP_URLS="http://www.alasir.com/software/ramspeed/ramsmp-3.5.0.tar.gz https://web.archive.org/web/2020id_/http://www.alasir.com/software/ramspeed/ramsmp-3.5.0.tar.gz"
RAMSMP_SHA256="39fb15493fb3c293575746d56f6ab9faaa1d876d8b1f0d8e5a4042d2ace95839"
RAMSMP_TARBALL="$BASE/ramsmp-3.5.0.tar.gz"

#Check de definitions
[[ $REPETICOES =~ ^[1-9][0-9]*$ && $TEMPO =~ ^[1-9][0-9]*$ ]] ||
    { echo "REPETICOES e TEMPO têm de ser números inteiros maiores que 0."; exit 1; }

TRAB="$(mktemp -d)"     #pasta temporária (apagada no fim)
VALORES="$TRAB/valores" #resultados das execuções do teste em curso
AVISOS="$TRAB/avisos"   #falhas e testes saltados, repetidos no resumo
GRUPO_ATUAL=""

titulo() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

#Funções mágicas de awk para escrever números e tempos
AWK_FMT='
function fmt(x) { return sprintf((x >= 1000) ? "%.0f" : (x >= 100) ? "%.1f" : (x >= 1) ? "%.2f" : "%.3f", x) }
function dur(s) { return (s < 10) ? sprintf("%.1f s", s) : (s < 60) ? sprintf("%d s", s) : sprintf("%dm %02ds", s / 60, s % 60) }
'

now() {
    date +%s.%N
}

# tempo decorrido INICIO -> segundos desde INICIO
elapsed() {
    awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'
}

duration() {
    awk "$AWK_FMT"'BEGIN { print dur(ARGV[1]) }' "$1"
}

#Apaga os ficheiros de teste e mata os processos que ficaram idle
clean() {
    pkill -KILL -f -- "--filename=$FIO_FILE" 2>/dev/null
    pkill -KILL -f -- "-f $IOZONE_FILE" 2>/dev/null
    rm -f "$IOZONE_FILE" "$FIO_FILE"
}

# --------------------------------------------------------------------------
# Instalar packages e compilar
# --------------------------------------------------------------------------

#instalar_em_falta COMANDO:PACOTE ... -> instala os pacotes por apt
instalar_em_falta() {
    FALTA=""
    for PAR in "$@"; do
        command -v "${PAR%%:*}" >/dev/null 2>&1 && continue
        case " $FALTA " in *" ${PAR##*:} "*) ;; *) FALTA="$FALTA ${PAR##*:}" ;; esac
    done
    [ -z "$FALTA" ] && return 0

    echo "A instalar:$FALTA"
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "  apt-get não encontrado. Instala à mão:$FALTA"
        return 1
    fi
    if [ "$SUDO" = "sudo" ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  É preciso sudo mode para instalar:$FALTA"
        return 1
    fi
    $SUDO apt-get update -qq >> "$LOG" 2>&1
    for PKG in $FALTA; do
        if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" >> "$LOG" 2>&1; then
            echo -e "\t$PKG (ver ${LOG#$BASE/})."
            [ "$PKG" = "iozone3" ] && echo "  O iozone3 está no repositório multiverse"
        fi
    done
}

#descarregar URL DESTINO (com limites de tempo, 120s)
descarregar() {
    curl -fsSL --connect-timeout 15 --max-time 120 -o "$2" "$1" 2>> "$LOG" || { rm -f "$2"; return 1; }
}

compilar_stream() {
    [ -x "$STREAM" ] && return 0
    command -v gcc >/dev/null 2>&1 || { echo "STREAM: falta o gcc (a saltar o teste)."; return 1; }
    mkdir -p "$STREAM_DIR"
    if [ ! -f "$STREAM_DIR/stream.c" ]; then
        echo "A instalar o STREAM..."
        for URL in $STREAM_URLS; do
            descarregar "$URL" "$STREAM_DIR/stream.c" && grep -q "STREAM_ARRAY_SIZE" "$STREAM_DIR/stream.c" && break
            rm -f "$STREAM_DIR/stream.c"
        done
    fi
    if [ ! -f "$STREAM_DIR/stream.c" ]; then
        echo "STREAM: stream.c não instalado (a saltar o teste)."
        rmdir "$STREAM_DIR" 2>/dev/null
        return 1
    fi
    echo "A compilar STREAM..."
    gcc -O3 -fopenmp "$STREAM_DIR/stream.c" -o "$STREAM" >> "$LOG" 2>&1 ||
        echo "STREAM: compilação falhou (ver ${LOG#$BASE/})."
}

#SHA-256 do tarball do RAMspeed (sem verificação se RAMSMP_SHA256 estiver vazio)
tarball_valido() {
    [ -z "$RAMSMP_SHA256" ] || echo "$RAMSMP_SHA256  $RAMSMP_TARBALL" | sha256sum -c --quiet - >/dev/null 2>&1
}

compilar_ramsmp() {
    [ -x "$RAMSMP" ] && return 0
    command -v gcc >/dev/null 2>&1 || { echo "RAMspeed: falta o gcc"; return 1; }
    if [ ! -f "$RAMSMP_DIR/build.sh" ]; then
        if [ ! -f "$RAMSMP_TARBALL" ]; then
            echo "A instalar o RAMspeed/SMP..."
            for URL in $RAMSMP_URLS; do
                descarregar "$URL" "$RAMSMP_TARBALL" && tarball_valido && break
                rm -f "$RAMSMP_TARBALL"
            done
        fi
        if [ ! -f "$RAMSMP_TARBALL" ]; then
            echo "RAMspeed: erro ao instalar ramsmp-3.5.0.tar.gz (a saltar o teste)."
            return 1
        fi
        tarball_valido || { echo "RAMspeed: o hash SHA-256 de $RAMSMP_TARBALL não coincide"; return 1; }
        mkdir -p "$RAMSMP_DIR"
        tar -xzf "$RAMSMP_TARBALL" -C "$RAMSMP_DIR" --strip-components=1 || { echo "RAMspeed: a extração falhou."; return 1; }
    fi
    echo "A compilar o RAMspeed/SMP..."
    (cd "$RAMSMP_DIR" && mkdir -p temp && yes | sh build.sh Linux) >> "$LOG" 2>&1
    [ -x "$RAMSMP" ] || echo "RAMspeed: a compilação falhou (ver ${LOG#$BASE/})."
}

versao() {
    printf '  %-14s %s\n' "$1" "${2:-não instalado}"
}

# --------------------------------------------------------------------------
#Segue o formato "Nome do teste" "metrica:unidade, metrica:unidade"
#Executa o COMANDO [argumentos] REPETICOES vezes.
#Mostra o valor e o tempo de execução de cada execução e acrescenta
#ao CSV as estatísticas.
medir() {
    GRUPO="$1"; METRICAS="$2"; shift 2
    NM="$(echo "$METRICAS" | awk -F, '{ print NF }')"
    REGEX="^[0-9.]+( [0-9.]+){$((NM - 1))}$"
    GRUPO_ATUAL="$GRUPO"
    FALHAS=0
    : > "$VALORES"

    echo
    echo "== $GRUPO =="
    INICIO="$(now)"
    for i in $(seq 1 "$REPETICOES"); do
        printf '  [%d/%d]  ' "$i" "$REPETICOES"
        T0="$(now)"
        echo "##### $GRUPO ($i/$REPETICOES)" >> "$LOG"
        RESULTADO="$("$@" 2>> "$LOG")"
        DT="$(elapsed "$T0")"
        if [[ $RESULTADO =~ $REGEX ]]; then
            echo "$RESULTADO" >> "$VALORES"
            echo "$RESULTADO" | awk -v m="$METRICAS" -v dt="$DT" "$AWK_FMT"'
                {
                    k = split(m, par, ",")
                    for (j = 1; j <= k; j++) { split(par[j], p, ":"); printf "%s %s %s   ", p[1], fmt($j), p[2] }
                    printf "(%s)\n", dur(dt)
                }'
        else
            echo "FALHOU (ver ${LOG#$BASE/})"
            FALHAS=$((FALHAS + 1))
        fi
    done
    DT="$(elapsed "$INICIO")"

    #Estatísticas de cada métrica (desvio padrão amostral, n-1) -> CSV
    if [ -s "$VALORES" ]; then
        awk -v g="$GRUPO" -v m="$METRICAS" -v t="$DT" '
            {
                for (i = 1; i <= NF; i++) {
                    soma[i] += $i; soma2[i] += $i * $i
                    if (NR == 1 || $i < min[i]) min[i] = $i
                    if (NR == 1 || $i > max[i]) max[i] = $i
                }
            }
            END {
                gsub(/,/, ";", g)
                k = split(m, par, ",")
                for (i = 1; i <= k; i++) {
                    split(par[i], p, ":")
                    media = soma[i] / NR
                    var = (NR > 1) ? (soma2[i] - NR * media * media) / (NR - 1) : 0
                    dp = (NR > 1) ? sprintf("%.3f", (var > 0) ? sqrt(var) : 0) : ""
                    printf "%s,%s,%s,%d,%.3f,%s,%.3f,%.3f,%.1f\n", g, p[1], p[2], NR, media, dp, min[i], max[i], t
                }
            }' "$VALORES" >> "$CSV"
    fi
    echo -e "\tTempo deste teste: $(duration "$DT")"
    if [ "$FALHAS" -gt 0 ]; then
        echo -e "\tATENÇÃO: $FALHAS execução(ões) falharam (ver ${LOG#$BASE/})."
        echo "Falharam $FALHAS de $REPETICOES execuções: $GRUPO" >> "$AVISOS"
    fi
    GRUPO_ATUAL=""
}

#saltar "Nome do teste" "motivo"
saltar() {
    echo
    echo "== $1 =="
    echo "  (a saltar: $2)"
    echo "Não executado: $1 ($2)" >> "$AVISOS"
}

# --------------------------------------------------------------------------
# TESTES

#Cada função corre o programa uma vez e escreve só os números, numa linha.
#O output completo daqui vai para o .log.
# --------------------------------------------------------------------------

rodar_cpu() {       #$1 = threads -> eventos/s e latência (ms)
    sysbench cpu --threads="$1" --time="$TEMPO" run | tee -ia "$LOG" |
        awk '/events per second/ { e = $4 } /95th percentile/ { l = $3 } END { print e, l }'
}

rodar_ram() {       #média das operações com inteiros em RAM (MB/s)
    "$RAMSMP" -b 3 -g "$RAM_GB" -p "$RAM_PROCS" | tee -ia "$LOG" |
        awk '{ for (i = 1; i < NF; i++) if ($i == "AVERAGE:") { print $(i + 1); exit } }'
}

rodar_stream() {    #testes RAM: Copy, Scale, Add, Triad (MB/s), só se o STREAM validar os resultados
    SAIDA="$(OMP_NUM_THREADS="$N_CPUS" "$STREAM" 2>&1)"
    echo "$SAIDA" >> "$LOG"
    echo "$SAIDA" | grep -q "Solution Validates" &&
        echo "$SAIDA" | awk '/^(Copy|Scale|Add|Triad):/ { printf "%s%s", s, $2; s = " " } END { print "" }'
}

rodar_iozone() {    #escrita e leitura (MiB/s); -I = I/O direto, sem a cache do sistema
    iozone -i 0 -i 1 -I -s 1g -r 4k -f "$IOZONE_FILE" | tee -ia "$LOG" |
        awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 6 { printf "%.1f %.1f\n", $3 / 1024, $5 / 1024 }'
    rm -f "$IOZONE_FILE"
}

rodar_fio() {       #$1 = read|write|randread|randwrite, $2 = bloco, $3 = iodepth
    #--minimal escreve uma linha com campos separados por ;
    # 8 = IOPS, 30 = percentil 99 da latência (microsegundos)
    fio --name=teste --filename="$FIO_FILE" --size="$FIO_TAMANHO" --rw="$1" --bs="$2" \
        --iodepth="$3" --ioengine="$FIO_MOTOR" --direct=1 --time_based --runtime="$TEMPO" \
        --ramp_time=5 --minimal | tee -ia "$LOG" |
        awk -F';' -v rw="$1" '/^3;/ {
            if (rw ~ /write/) { bw = 48; lat = 71 } else { bw = 7; lat = 30 }
            split($lat, p, "=")
            printf "%.1f %d %d\n", $bw / 1024, $(bw + 1), p[2]
        }'
}

#falta avaliar latência, ms
rodar_iperf() {     #$1 = "" ou "-R" (reverso) -> Mbit/s recebidos
    iperf3 -c "$IPERF_SERVER" -t "$IPERF_TEMPO" -O 2 -f m $1 | tee -ia "$LOG" |
        awk '/receiver/ { print $7 }'
}

# --------------------------------------------------------------------------
# Resumo final
# --------------------------------------------------------------------------
resumo() {
    titulo "RESUMO FINAL"
    if [ "$(wc -l < "$CSV")" -gt 1 ]; then
        awk -F, "$AWK_FMT"'
            function larg(s,   t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
            function dir(s, w) { return sprintf("%" (w + length(s) - larg(s)) "s", s) }
            BEGIN {
                printf "    Métrica          %s %s %s %s %s %s\n", dir("n", 2), dir("Média", 9),
                    dir("Desvio", 9), dir("CV %", 9), dir("Mín", 9), dir("Máx", 9)
            }
            NR > 1 {
                if ($1 != ultimo) { printf "  %s  [%s]\n", $1, dur($9); ultimo = $1 }
                cv = ($6 != "" && $5 != 0) ? sprintf("%.1f", $6 / $5 * 100) : "-"
                printf "    %-16s %2d %9s %9s %9s %9s %9s\n", $2, $4, fmt($5), ($6 == "") ? "-" : fmt($6), cv, fmt($7), fmt($8)
            }' "$CSV"
    else
        echo -e "\tNenhum teste chegou ao fim."
    fi
    [ -s "$AVISOS" ] && { echo; cat "$AVISOS"; }
    echo
    echo "  Tempo total: $(duration $((SECONDS - T_INICIO)))"
    echo "  Desvio = desvio padrão entre repetições; CV = desvio/média (acima de 5% os"
    echo "  resultados são pouco estáveis). Nas latências, menor é melhor."
}

#Interrupt Ctrl-C 
#apaga os ficheiros de teste e mostra o resumo do que já terminou.
interromper() {
    trap '' INT TERM HUP
    clean
    echo
    echo "Interrompido; ficheiros de teste apagados."
    [ -n "$GRUPO_ATUAL" ] && echo "Interrompido durante: $GRUPO_ATUAL (não entra no resumo)" >> "$AVISOS"
    resumo
    exit 130
}

echo "grupo,metrica,unidade,n,media,desvio,min,max,tempo_s" > "$CSV"

#Main
#Resumo de sistema+testes inicial
#tee -i: o relatório continua a ser gravado mesmo com Ctrl-C.
{
    trap interromper INT TERM HUP
    trap 'clean; rm -rf "$TRAB"' EXIT
    T_INICIO=$SECONDS

    echo "Benchmark iniciado em: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Máquina: $(hostname)"

    titulo "INFORMAÇÃO DO SISTEMA"
    echo "Kernel: $(uname -r)"
    VIRT="$(systemd-detect-virt 2>/dev/null)"
    echo "Virtualização: ${VIRT:-desconhecida}"
    echo "Uptime (a partir do arranque do kernel): $(uptime -s)"
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze 2>/dev/null | head -n 2
    fi
    lscpu | grep -E "Model name|^CPU\(s\)|Thread|Core|L3 cache"
    echo
    free -h
    echo
    lsblk -d -o NAME,SIZE,ROTA,MODEL 2>/dev/null
    echo
    echo "Disco de teste: $(df -hT "$BASE" 2>/dev/null | awk 'NR == 2 { print $1 " (" $2 "), " $5 " livres" }')"

    titulo "PROGRAMAS"
    instalar_em_falta curl:curl gcc:build-essential make:build-essential sysbench:sysbench \
                      iozone:iozone3 fio:fio iperf3:iperf3
    compilar_stream
    compilar_ramsmp
    echo
    versao "gcc" "$(gcc --version 2>/dev/null | head -n 1)"
    versao "sysbench" "$(sysbench --version 2>/dev/null | head -n 1)"
    versao "iozone" "$(timeout 5 iozone -v 2>&1 | grep -m1 -i -E 'version|revision' |
        sed -E -e 's/^[[:space:]]+//' -e 's/\$Revision: *([0-9.]+) *\$/\1/')"
    versao "fio" "$(fio --version 2>/dev/null | head -n 1)"
    versao "iperf3" "$(iperf3 --version 2>/dev/null | head -n 1)"
    versao "STREAM" "$([ -x "$STREAM" ] && grep -m1 "Revision" "$STREAM_DIR/stream.c" 2>/dev/null |
        sed -e 's#^[[:space:]]*/\*[[:space:]]*##' -e 's#[[:space:]]*\*/[[:space:]]*$##')"
    versao "RAMspeed/SMP" "$([ -x "$RAMSMP" ] && timeout 5 "$RAMSMP" 2>&1 | grep -m1 "RAMspeed")"

    #Estimativa só com o sysbench e o fio (os outros testes acrescentam mais).
    MINIMO=0
    command -v sysbench >/dev/null 2>&1 && MINIMO=$((MINIMO + REPETICOES * TEMPO * (1 + (N_CPUS > 1))))
    command -v fio >/dev/null 2>&1 && MINIMO=$((MINIMO + REPETICOES * 4 * (TEMPO + 5)))
    echo
    echo "Repetições por teste: $REPETICOES"
    [ "$MINIMO" -gt 0 ] && echo "Duração mínima: $(duration "$MINIMO") só com o sysbench e o fio; os outros testes acrescentam mais."

    # CPU
    if command -v sysbench >/dev/null 2>&1; then
        medir "CPU 1 thread (sysbench)" "eventos:ev/s,lat p95:ms" rodar_cpu 1
        [ "$N_CPUS" -gt 1 ] &&
            medir "CPU $N_CPUS threads (sysbench)" "eventos:ev/s,lat p95:ms" rodar_cpu "$N_CPUS"
    else
        saltar "CPU (sysbench)" "sysbench não instalado"
    fi

    # Memória
    if [ -x "$RAMSMP" ]; then
        medir "RAM (RAMspeed INTmem ${RAM_GB} GB)" "media:MB/s" rodar_ram
    else
        saltar "RAM (RAMspeed)" "ramsmp não encontrado"
    fi
    if [ -x "$STREAM" ]; then
        medir "RAM (STREAM $N_CPUS threads)" "Copy:MB/s,Scale:MB/s,Add:MB/s,Triad:MB/s" rodar_stream
    else
        saltar "RAM (STREAM)" "stream não encontrado"
    fi

    # Disco
    if command -v iozone >/dev/null 2>&1; then
        medir "Disco (IOzone 1 GB bloco 4k)" "escrita:MiB/s,leitura:MiB/s" rodar_iozone
    else
        saltar "Disco (IOzone)" "iozone não instalado"
    fi
    if ! command -v fio >/dev/null 2>&1; then
        saltar "Disco (fio)" "fio não instalado"
    elif ! fio --enghelp 2>&1 | grep -qw "$FIO_MOTOR"; then
        saltar "Disco (fio)" "motor de I/O $FIO_MOTOR indisponível; muda FIO_MOTOR no início do script"
    else
        FIO_METRICAS="largura:MiB/s,IOPS:IOPS,lat p99:us"
        medir "Disco seq. escrita (fio 1M)"   "$FIO_METRICAS" rodar_fio write     1M 8
        medir "Disco seq. leitura (fio 1M)"   "$FIO_METRICAS" rodar_fio read      1M 8
        medir "Disco aleat. escrita (fio 4k)" "$FIO_METRICAS" rodar_fio randwrite 4k 32
        medir "Disco aleat. leitura (fio 4k)" "$FIO_METRICAS" rodar_fio randread  4k 32
        rm -f "$FIO_FILE"
    fi

    # Rede
    if [ -z "$IPERF_SERVER" ]; then
        saltar "Rede (iperf3)" "nenhum servidor indicado; usa $0 IP_DO_SERVIDOR"
    elif ! command -v iperf3 >/dev/null 2>&1; then
        saltar "Rede (iperf3)" "iperf3 não instalado"
    else
        medir "Rede cliente->servidor (iperf3)" "recebido:Mbit/s" rodar_iperf
        medir "Rede servidor->cliente (iperf3)" "recebido:Mbit/s" rodar_iperf -R
    fi

    resumo
    echo
    echo "Benchmark terminado em: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee -i "$OUT"
RC="${PIPESTATUS[0]}"

rm -rf "$TRAB"
echo
echo "Relatório: ${OUT#$BASE/}"
echo "CSV:       ${CSV#$BASE/}"
echo "Log:       ${LOG#$BASE/}"
exit "$RC"


# --------------------------------------------------------------------------
# Referências
# --------------------------------------------------------------------------
# sysbench, https://github.com/akopytov/sysbench
# STREAM,   https://github.com/jeffhammond/STREAM
#           https://www.cs.virginia.edu/stream/
# ramspeed, https://github.com/cruvolo/ramspeed-smp
#           http://www.alasir.com/software/ramspeed
# iozone,   https://iozone.org/
# fio,      https://github.com/axboe/fio
# iperf3,   https://github.com/esnet/iperf
#benchmark, https://www.nkn-it.de/benchmark_demo/
# Ferramenta IA, Claude [estruturação do script, estatísticas em awk, filtros de output
# tratamento do Ctrl-C, revisão e melhoria do script]