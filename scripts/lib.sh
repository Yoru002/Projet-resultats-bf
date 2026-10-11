# install_si_different SOURCE DEST [DROITS]
# Retourne 0 si DEST a changé, 1 sinon.
install_si_different() {
  if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
    install -m "${3:-644}" "$1" "$2"
    return 0
  fi
  return 1
}
