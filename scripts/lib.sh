install_si_different() {   # $1 = fichier candidat, $2 = destination, $3 = droits
if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
install -m "${3:-644}" "$1" "$2"
return 0               
fi
return 1                 
}