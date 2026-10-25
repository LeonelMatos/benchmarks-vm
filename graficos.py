#!/usr/bin/env python3
# Gera as duas figuras do paper a partir dos resultados do benchmarks.sh.
#   figuras/overhead.png  overhead (%) do Proxmox VE e do VirtualBox face ao nativo
#   figuras/memoria.png   largura de banda da memória nos três cenários
#
# Uso:  pip install matplotlib
#       python3 graficos.py [pasta_dos_resultados]

import csv, glob, os, re, sys
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1] if len(sys.argv) > 1 else "exemplos"
SAIDA = "figuras"
PASTAS = {
    "A": "resultados_native_server",  # referência (mesmo SO das VMs)
    "B": "resultados_proxmox",
    "C": "resultados_virtualbox",
    "C2": "resultados_virtualbox_bridged",  # 2.ª sessão do VirtualBox, usada só na rede
}
COR = {"A": "#8c8b87", "B": "#2a78d6", "C": "#eb6834"}
NOME = {"A": "Native", "B": "Proxmox VE", "C": "VirtualBox"}
TRACO = {"A": "", "B": "", "C": "////"}

plt.rcParams.update(
    {
        "font.size": 7,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "hatch.color": "white",
        "hatch.linewidth": 0.6,
    }
)


def ficheiro(cenario, ext):
    return glob.glob(os.path.join(BASE, PASTAS[cenario], "*." + ext))[0]


def ler(cenario):
    """CSV -> {(grupo, métrica): (média, desvio)}. '8 threads' e '16 threads' passam a 'N threads'."""
    dados = {}
    with open(ficheiro(cenario, "csv"), encoding="utf-8") as f:
        for linha in csv.DictReader(f):
            grupo = re.sub(r"\d+ threads", "N threads", linha["grupo"])
            dados[(grupo, linha["metrica"])] = (
                float(linha["media"]),
                float(linha["desvio"] or 0),
            )
    return dados


def rede_sem_falhas(cenario):
    """Média do iperf3 servidor->cliente sem as execuções que deram 0 Mbit/s (ligação falhada)."""
    with open(ficheiro(cenario, "txt"), encoding="utf-8") as f:
        texto = f.read().split("== Rede servidor->cliente")[1].split("RESUMO")[0]
    validos = [
        float(v) for v in re.findall(r"recebido ([\d.]+) Mbit/s", texto) if float(v) > 0
    ]
    return sum(validos) / len(validos)


dados = {c: ler(c) for c in PASTAS}


def media(cenario, chave):
    if cenario == "C" and chave[0].startswith(
        "Rede"
    ):  # rede do VirtualBox: 2.ª sessão (bridged)
        if chave[0].startswith("Rede servidor"):
            return rede_sem_falhas("C2")
        return dados["C2"][chave][0]
    return dados[cenario][chave][0]


def overhead(cenario, chave):
    """O > 0: VM mais lenta do que o nativo."""
    return (1 - media(cenario, chave) / media("A", chave)) * 100


os.makedirs(SAIDA, exist_ok=True)

# ---- Figura 1: overhead por métrica ----------------------------------------
METRICAS = [
    ("CPU, 1 thread", ("CPU 1 thread (sysbench)", "eventos")),
    ("CPU, all threads*", ("CPU N threads (sysbench)", "eventos")),
    ("RAMspeed INTmem", ("RAM (RAMspeed INTmem 8 GB)", "media")),
    ("STREAM Triad*", ("RAM (STREAM N threads)", "Triad")),
    ("IOzone write", ("Disco (IOzone 1 GB bloco 4k)", "escrita")),
    ("IOzone read", ("Disco (IOzone 1 GB bloco 4k)", "leitura")),
    ("fio seq. write", ("Disco seq. escrita (fio 1M)", "largura")),
    ("fio seq. read", ("Disco seq. leitura (fio 1M)", "largura")),
    ("fio rand. write", ("Disco aleat. escrita (fio 4k)", "largura")),
    ("fio rand. read", ("Disco aleat. leitura (fio 4k)", "largura")),
    ("iPerf3 VM→server", ("Rede cliente->servidor (iperf3)", "recebido")),
    ("iPerf3 server→VM", ("Rede servidor->cliente (iperf3)", "recebido")),
]

fig, ax = plt.subplots(figsize=(3.5, 3.6))
y = range(len(METRICAS))
for i, c in enumerate(["B", "C"]):
    valores = [overhead(c, chave) for _, chave in METRICAS]
    posicoes = [p + (i - 0.5) * 0.4 for p in y]
    ax.barh(
        posicoes,
        valores,
        height=0.38,
        color=COR[c],
        hatch=TRACO[c],
        edgecolor="white",
        linewidth=0.5,
        label=NOME[c],
    )
    for p, v in zip(posicoes, valores):
        if abs(v) < 5:
            ax.text(
                max(v, 0) + 2, p, f"{v:.1f}", va="center", fontsize=5.5, color="#52514e"
            )
ax.axvline(0, color="#0b0b0b", linewidth=0.8)
ax.set_yticks(list(y), [nome for nome, _ in METRICAS])
ax.invert_yaxis()
ax.set_xlabel("Overhead relative to native (%)\n← VM faster          VM slower →")
ax.grid(axis="x", color="#e1e0d9", linewidth=0.5)
ax.set_axisbelow(True)
ax.legend(loc="lower left", frameon=False)
fig.tight_layout()
fig.savefig(os.path.join(SAIDA, "overhead.png"), dpi=300)

# ---- Figura 2: largura de banda da memória ---------------------------------
MEMORIA = [
    ("RAMspeed\nINTmem", ("RAM (RAMspeed INTmem 8 GB)", "media")),
    ("STREAM\nCopy*", ("RAM (STREAM N threads)", "Copy")),
    ("STREAM\nScale*", ("RAM (STREAM N threads)", "Scale")),
    ("STREAM\nAdd*", ("RAM (STREAM N threads)", "Add")),
    ("STREAM\nTriad*", ("RAM (STREAM N threads)", "Triad")),
]

fig, ax = plt.subplots(figsize=(3.5, 2.2))
x = range(len(MEMORIA))
for i, c in enumerate(["A", "B", "C"]):
    medias = [dados[c][chave][0] / 1000 for _, chave in MEMORIA]
    desvios = [dados[c][chave][1] / 1000 for _, chave in MEMORIA]
    ax.bar(
        [p + (i - 1) * 0.27 for p in x],
        medias,
        width=0.25,
        yerr=desvios,
        color=COR[c],
        hatch=TRACO[c],
        edgecolor="white",
        linewidth=0.5,
        label=NOME[c],
        error_kw={"elinewidth": 0.6, "capsize": 1.5, "ecolor": "#52514e"},
    )
ax.set_xticks(list(x), [nome for nome, _ in MEMORIA])
ax.set_ylabel("Bandwidth (GB/s)")
ax.grid(axis="y", color="#e1e0d9", linewidth=0.5)
ax.set_axisbelow(True)
ax.legend(loc="upper left", frameon=False, ncol=3)
ax.set_ylim(0, ax.get_ylim()[1] * 1.12)
fig.tight_layout()
fig.savefig(os.path.join(SAIDA, "memoria.png"), dpi=300)

print("Figuras gravadas em", SAIDA + "/")
