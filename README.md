# benchmarks-vm

Script em Bash que mede CPU, memória, disco e rede numa máquina Linux, nativa ou virtual, e grava os resultados em texto e CSV.
 
Desenvolvido para o trabalho *What Does One Extra Layer Cost?* da cadeira de Virtualização e Centro de Dados (UBI, 2026), que compara o mesmo Ubuntu Server em nativo, numa VM do Proxmox VE (tipo 1) e numa VM do VirtualBox (tipo 2). A pasta `exemplos/` tem os resultados usados no artigo.
 
> J. Moreira, L. Matos e F. Gomes, "What Does One Extra Layer Cost?", trabalho da cadeira de Virtualização e Centro de Dados, Universidade da Beira Interior, 2026.

## Requisitos
 
- Ubuntu ou Debian. Foi testado em _Ubuntu Server 26.04.1_.
- Internet na primeira execução: o script instala `sysbench`, `iozone3`, `fio`, `iperf3` `build-essential` e os _source files_ de STREAM e RAMspeed/SMP, depois compilados. O `iozone3` está no repositório *multiverse*.
- Um **mínimo de 2 GB** livres no disco onde está o script, porque os ficheiros de teste do disco ficam lá.
- RAM suficiente para o RAMspeed (os testes foram feitos com 16 GB).
- Para a rede, uma segunda máquina na LAN com `iperf3 -s` (_listening on port 5201_).

## Uso
 
```bash
git clone https://github.com/LeonelMatos/benchmarks-vm
cd benchmarks-vm
chmod +x benchmarks.sh
 
REPETICOES=1 ./benchmarks.sh 192.168.1.93   # ensaio rápido: instala tudo e confirma que os testes correm
./benchmarks.sh 192.168.1.93                # execução completa, com rede
./benchmarks.sh                             # sem IP: salta o iperf3
```

No servidor:
```bash
iperf3 -s
```

Com as atuais variáveis e números de repetições, uma execução completa demora cerca de 1 hora.

É possível mudar `REPETICOES` e `TEMPO` na linha de comando. Os restantes valores no _script_ também podem ser alterados.

Ctrl-C interrompe a execução e guarda os resultados dos testes que já terminaram.

## Resultados

| Ficheiro | Conteúdo |
| --- | --- |
| `benchmark_YYYY_MM_DD_HH-MM-SS.txt` | relatório completo: sistema, versões, cada repetição e resumo final |
| `benchmark_YYYY_MM_DD_HH-MM-SS.csv` | uma linha por métrica: `grupo,metrica,unidade,n,media,desvio,min,max,tempo_s` |
| `benchmark_YYYY_MM_DD_HH-MM-SS.log` | log de instalação e output completo dos programas |
