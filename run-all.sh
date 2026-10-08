#!/usr/bin/env bash
# Déploie et vérifie tout l'examen CinéK8s (Parties 2 à 6 + bonus).
# Usage : ./run-all.sh            (Minikube doit être démarré)
#         SKIP_TESTS=1 ./run-all.sh   (saute les tests Maven)
#         CLEANUP=1 ./run-all.sh      (supprime le namespace à la fin)
# Windows : à lancer depuis Git Bash. Aucun fichier hosts n'est modifié :
# l'Ingress est testé via un port-forward et l'en-tête "Host: cinema.local".

cd "$(dirname "$0")" || exit 1
export MSYS_NO_PATHCONV=1

NS=cinema-exam
LOCAL_PORT=8088
PASS=0; FAIL=0; PF_PID=""

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "=== $1"; }
check() { # check "description" commande...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi
}
contains() { # contains "description" "attendu" commande...
  local d="$1" exp="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if grep -q -- "$exp" <<<"$out"; then ok "$d"; else ko "$d (attendu : $exp ; obtenu : ${out:0:120})"; fi
}
ingress() { curl -s -m 10 -H "Host: cinema.local" "http://localhost:$LOCAL_PORT$1" "${@:2}"; }
ingress_code() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: cinema.local" "http://localhost:$LOCAL_PORT$1" "${@:2}"; }
wait_ready() { kubectl -n $NS rollout status deploy/"$1" --timeout=240s >/dev/null 2>&1; }
cleanup_pf() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; }
trap cleanup_pf EXIT

step "0. Prérequis"
for t in docker kubectl minikube curl; do
  command -v $t >/dev/null 2>&1 && ok "$t présent" || { ko "$t introuvable"; echo "Prérequis manquant, arrêt."; exit 1; }
done
minikube status >/dev/null 2>&1 && ok "Minikube démarré" || { ko "Minikube arrêté (minikube start)"; exit 1; }
docker info >/dev/null 2>&1 && ok "Docker démarré" || { ko "Docker arrêté"; exit 1; }

step "1. Tests unitaires Maven (Partie 2)"
if [ -n "$SKIP_TESTS" ]; then
  echo "  (ignoré : SKIP_TESTS)"
else
  # Maven dans un conteneur : aucun JDK/JAVA_HOME local nécessaire
  ROOT=$(pwd -W 2>/dev/null || pwd)
  for s in movie-service ticket-service; do
    docker run --rm -v "$ROOT/$s:/app" -v cinek8s-m2:/root/.m2 -w /app       maven:3.9-eclipse-temurin-21 mvn -q -B test >/dev/null 2>&1       && ok "tests $s" || ko "tests $s"
  done
fi

step "2. Build des images Docker (Partie 3)"
docker build -q -t movie-service:1.0.0  ./movie-service  >/dev/null && ok "image movie-service:1.0.0"  || ko "build movie-service"
docker build -q -t ticket-service:1.0.0 ./ticket-service >/dev/null && ok "image ticket-service:1.0.0" || ko "build ticket-service"
contains "movie tourne en non-root (uid 10001)" "uid=10001" docker run --rm --entrypoint id movie-service:1.0.0
contains "ticket tourne en non-root (uid 10001)" "uid=10001" docker run --rm --entrypoint id ticket-service:1.0.0

step "3. Docker Compose (Partie 3.2)"
if docker compose up -d --build --wait >/dev/null 2>&1; then
  for i in $(seq 1 40); do
    curl -s -m 3 localhost:8082/actuator/health/readiness | grep -q '"UP"' && break; sleep 2
  done
  contains "whoami -> environment compose" '"environment":"compose"' curl -s -m 10 localhost:8080/api/movies/whoami
  contains "réservation à 21.00" '"total":21.00' curl -s -m 10 -X POST localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":1,"seats":2}'
else
  ko "docker compose up (ports 8080/8082 libres ?)"
fi
docker compose down >/dev/null 2>&1

step "4. Chargement des images et déploiement Minikube (Partie 4)"
minikube image load movie-service:1.0.0  && ok "image movie chargée"  || ko "chargement movie"
minikube image load ticket-service:1.0.0 && ok "image ticket chargée" || ko "chargement ticket"
kubectl apply -f k8s/ --dry-run=client >/dev/null 2>&1 && ok "manifests valides" || ko "manifests invalides"
kubectl apply -f k8s/ >/dev/null 2>&1 && ok "kubectl apply -f k8s/" || ko "kubectl apply"
wait_ready movie  && ok "Deployment movie prêt"  || ko "Deployment movie non prêt"
wait_ready ticket && ok "Deployment ticket prêt" || ko "Deployment ticket non prêt"
kubectl -n $NS get pods
check "2 Pods movie Ready"  test "$(kubectl -n $NS get deploy movie  -o jsonpath='{.status.readyReplicas}')" = "2"
check "2 Pods ticket Ready" test "$(kubectl -n $NS get deploy ticket -o jsonpath='{.status.readyReplicas}')" = "2"
contains "ticket -> movie par le nom du Service" '"environment"' kubectl -n $NS exec deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami
contains "readiness ticket UP avec movie" '"movie":{"status":"UP"}' kubectl -n $NS exec deploy/ticket -- wget -qO- http://localhost:8086/actuator/health/readiness
contains "ConfigMap movie-config appliquée" "$(grep -o 'MOVIE_ENVIRONMENT: .*' k8s/10-config.yaml | cut -d' ' -f2)" kubectl -n $NS exec deploy/movie -- printenv MOVIE_ENVIRONMENT

step "5. Ingress (Partie 5)"
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller $LOCAL_PORT:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
contains "GET /api/movies"  "Pod Fiction" ingress /api/movies
contains "POST /api/tickets (film 3 x 10 = 90.00)" '"total":90.00' ingress /api/tickets -X POST -H 'Content-Type: application/json' -d '{"movieId":3,"seats":10}'
HOSTS=$(for i in $(seq 1 10); do ingress /api/movies/whoami | grep -o '"hostname":"[^"]*"'; done | sort -u | wc -l)
[ "$HOSTS" -ge 2 ] && ok "load-balancing : $HOSTS Pods movie distincts" || ko "load-balancing : $HOSTS Pod(s)"
[ "$(ingress_code /actuator/health)" = "404" ] && ok "/actuator/health non exposé (404)" || ko "/actuator/health exposé"

step "6. Scénario : movie à 0 réplica (Partie 6.1)"
kubectl -n $NS scale deploy/movie --replicas=0 >/dev/null
sleep 35
[ "$(ingress_code /api/tickets)" = "503" ] && ok "GET /api/tickets -> 503" || ko "code attendu 503"
check "ticket 0/1 Ready" test "$(kubectl -n $NS get deploy ticket -o jsonpath='{.status.readyReplicas}')" = ""
check "ticket n'a pas redémarré (RESTARTS=0)" test "$(kubectl -n $NS get pods -l app=ticket -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | tr -d ' 0')" = ""
kubectl -n $NS scale deploy/movie --replicas=2 >/dev/null
wait_ready movie
sleep 15
[ "$(ingress_code /api/tickets)" = "200" ] && ok "retour à la normale (200)" || ko "ticket ne se rétablit pas"

step "7. Mission dépannage (Partie 6.2)"
kubectl apply -f broken/ticket-debug.yaml >/dev/null 2>&1
wait_ready ticket-debug && ok "ticket-debug corrigé -> 1/1 Running" || ko "ticket-debug toujours cassé"
kubectl delete -f broken/ticket-debug.yaml >/dev/null 2>&1

step "8. Bonus B1 (securityContext) et B2 (rolling update)"
contains "B1 : uid 10001" "uid=10001" kubectl -n $NS exec deploy/movie -- id
contains "B1 : système de fichiers en lecture seule" "Read-only file system" kubectl -n $NS exec deploy/movie -- touch /test
contains "B2 : maxUnavailable 0" "0" kubectl -n $NS get deploy movie -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}'
( for i in $(seq 1 150); do ingress_code /api/movies; echo; sleep 0.2; done | sort | uniq -c > "${TMPDIR:-/tmp}/rolling.txt" ) &
LOOP=$!
sleep 1
kubectl -n $NS rollout restart deploy/movie >/dev/null
wait_ready movie
wait $LOOP
RES=$(tr -s ' ' < "${TMPDIR:-/tmp}/rolling.txt" | tr '
' ';')
BAD=$(awk '$2 != "200" && NF == 2 {n += $1} END {print n+0}' "${TMPDIR:-/tmp}/rolling.txt")
[ "$BAD" = "0" ] && ok "B2 : 0 erreur pendant le rollout ($RES)" || ko "B2 : $BAD erreur(s) pendant le rollout ($RES)"

step "Résultat"
echo "  $PASS vérifications réussies, $FAIL échec(s)"
if [ -n "$CLEANUP" ]; then
  kubectl delete ns $NS >/dev/null 2>&1 && echo "  namespace $NS supprimé"
fi
[ "$FAIL" -eq 0 ]
