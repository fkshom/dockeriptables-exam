BEGIN { nf = split("0 0 27 7 6 5 5 20 20",w) }
NF && !/^Chain/ {
    for (i=3; i<=nf; i++) {
        printf "%-*s", w[i], $i
    }
    sub("^([[:space:]]*[^[:space:]]+){"nf"}[[:space:]]*","")
}
{ print }
