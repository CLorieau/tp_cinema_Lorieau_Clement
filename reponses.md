> 🚀 **Correction rapide :** lancer `./run-all.sh` (depuis Git Bash, Docker et Minikube démarrés) construit les images, déploie sur Minikube et exécute tous les tests et vérifications (tests Maven, Docker, Compose, Kubernetes, Ingress, scénarios de la Partie 6, bonus). Options : `SKIP_TESTS=1` pour sauter les tests Maven, `CLEANUP=1` pour supprimer le namespace à la fin.

# Examen CinéK8s — LORIEAU Clément

> Remarque : les ports réels du code diffèrent de l'énoncé : `movie-service` écoute sur **8085** et `ticket-service` sur **8086** (pas 8080). Dockerfile, Compose et `containerPort` utilisent ces ports ; les **Services** Kubernetes exposent 8080 (→ port nommé `http`), donc `MOVIE_URL=http://movie:8080` reste valable.

## Partie 1
**Q1.1** `MovieClient` lit la propriété `movie.url` (`@Value("${movie.url}")`). Elle se surcharge avec la variable d'environnement `MOVIE_URL` (relaxed binding).

**Q1.2** (a) film inexistant → `422` ; (b) pas assez de places → `409` ; (c) movie-service injoignable → `503`. (Bonus : seats < 1 → `400`.)

**Q1.3** Ligne complétée : `include: readinessState,movie`.
La dépendance va dans la readiness car si movie tombe, il faut seulement retirer ticket du Service (plus de trafic), ce que fait un échec de readiness. Un échec de liveness ferait redémarrer ticket par le kubelet, ce qui ne résout rien (le problème est chez movie) et provoquerait des redémarrages en cascade.

**Q1.4**

| Endpoint | Probe(s) | Conséquence d'un échec |
|---|---|---|
| `/actuator/health/liveness` | `startupProbe` et `livenessProbe` | le kubelet **redémarre** le conteneur (après `failureThreshold` échecs) |
| `/actuator/health/readiness` | `readinessProbe` | le Pod est retiré des endpoints du Service (plus de trafic), **sans redémarrage** |

`server.shutdown: graceful` laisse finir les requêtes en cours avant l'arrêt du Pod, pour qu'un rolling update ne coupe pas de requêtes.

## Partie 2
Je n'ai pas lancé les jars en local (JDK 25 installé, projet en Java 21) : le comportement a été vérifié dans Docker Compose (Partie 3) et Kubernetes, avec le même code.
```
$ curl localhost:8082/actuator/health/readiness   (via Compose)
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}
```
Le scénario « movie coupé » a été observé dans Kubernetes (Partie 6.1) : readiness en échec (503), liveness inchangée, pas de redémarrage.

**Q2.1** Une variable d'environnement évite de modifier le fichier (donc de rebuilder) : Spring Boot externalise la configuration, avec une priorité des variables d'environnement sur `application.yaml`, et le relaxed binding (`SERVER_PORT` → `server.port`).

**Q2.2** La liveness dit « le processus est sain » ; ticket n'est pas cassé, c'est sa dépendance qui l'est. Redémarrer ticket n'y changerait rien. La readiness dit « je ne peux pas servir pour l'instant » : on arrête seulement d'envoyer du trafic.

## Partie 3
```
$ docker images | grep -E 'movie-service|ticket-service'
movie-service:1.0.0    231MB
ticket-service:1.0.0   231MB
$ docker run --rm --entrypoint id movie-service:1.0.0
uid=10001(spring) gid=101(spring) groups=101(spring)

$ curl localhost:8080/api/movies/whoami
{"hostname":"342fe5b83ca6","environment":"compose"}
$ curl -X POST localhost:8082/api/tickets -d '{"movieId":1,"seats":2}'
{"id":1,"movieId":1,"movieTitle":"Pod Fiction","seats":2,"total":21.00,...}
```
Fichiers : `movie-service/Dockerfile`, `ticket-service/Dockerfile`, `docker-compose.yaml`.

**Q3.1** Les couches Docker sont mises en cache dans l'ordre. Le `pom.xml` change rarement : la couche `dependency:go-offline` (la plus lente) est réutilisée. En modifiant une ligne de Java, seules `COPY src` et `mvn package` sont rejouées, sans retélécharger les dépendances.

**Q3.2** `MaxRAMPercentage` s'adapte à la limite mémoire du conteneur (75 % de la limite), alors que `-Xmx512m` est figé : trop grand ⇒ OOMKilled, trop petit ⇒ mémoire gaspillée si on change la limite.

**Q3.3** Rien de bloquant : les Pods ticket démarrent, mais leur readiness échoue (movie injoignable), ils restent `0/1` et ne reçoivent pas de trafic ; dès que movie est prêt, la readiness passe `UP` sans intervention. L'orchestration se fait par probes et boucle de réconciliation, pas par ordre de démarrage.

## Partie 4
```
$ kubectl get pods
NAME                      READY   STATUS    RESTARTS   AGE
movie-568bd7bc65-f44hj    1/1     Running   0          35s
movie-568bd7bc65-kmqrp    1/1     Running   0          35s
ticket-7bc5799688-272sk   1/1     Running   0          35s
ticket-7bc5799688-cfjsw   1/1     Running   0          35s

$ kubectl get endpoints movie ticket
movie    10.244.0.15:8085,10.244.0.17:8085
ticket   10.244.0.14:8086,10.244.0.16:8086

$ kubectl exec deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami
{"environment":"kubernetes","hostname":"movie-568bd7bc65-f44hj"}
$ kubectl exec deploy/ticket -- wget -qO- http://localhost:8086/actuator/health/readiness
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}

# Réservation (movie 3 × 10 places, via l'Ingress)
{"id":1,"movieId":3,"movieTitle":"Docker Wars","seats":10,"total":90.00,...}
```
Images chargées avec `minikube image load` (option C).

**Q4.1** `kubectl apply -f dossier/` traite les fichiers par ordre alphabétique. Les préfixes numériques garantissent que le Namespace (00) existe avant les ConfigMaps (10) et les Deployments (20, 30), qui eux-mêmes précèdent l'Ingress (40).

**Q4.2** C'est la `startupProbe` : tant que Spring Boot n'a pas démarré (jusqu'à 30 × 2 s), elle échoue et suspend liveness/readiness, donc `0/1`. Ce n'est pas une anomalie.

**Q4.3** Avec `Always`, le kubelet tente de pull l'image depuis docker.io à chaque démarrage de Pod ; l'image n'existe que localement, donc `ErrImagePull` / `ImagePullBackOff`.

## Partie 5
Addon `ingress` déjà actif. Je n'ai pas modifié le fichier hosts de Windows : j'ai fait un `kubectl port-forward` sur le contrôleur nginx et envoyé l'en-tête `Host: cinema.local` (équivalent fonctionnel).
```
$ kubectl describe ingress cinema
  cinema.local
     /api/movies    movie:http (10.244.0.15:8085,10.244.0.17:8085)
     /api/tickets   ticket:http (10.244.0.16:8086,10.244.0.14:8086)

GET /api/movies               → liste des films
POST /api/tickets (film 3 × 10) → total 90.00
whoami ×6 → movie-568bd7bc65-kmqrp, kmqrp, f44hj, f44hj, f44hj, kmqrp
GET /actuator/health          → 404
```
**Q5.1** 2 Pods distincts ont répondu. C'est le **Service** `movie` (kube-proxy, répartition entre les endpoints) qui répartit la charge, derrière l'Ingress.

**Q5.2** Avec `Exact`, seul `/api/movies` serait routé ; `/api/movies/1` et `/api/movies/whoami` donneraient 404 de l'Ingress.

**Q5.3** `404` : seuls `/api/movies` et `/api/tickets` sont routés. C'est souhaitable : les endpoints Actuator (santé détaillée, infos internes) ne doivent pas être exposés publiquement ; ils servent uniquement aux probes du kubelet, en interne.

## Partie 6
### 6.1 Prédictions (avant manipulation)
(a) `0/1`, `RESTARTS` 0 ; (b) endpoints de ticket vides ; (c) `503` ; (d) liveness `UP`.

Observé :
```
ticket-7bc5799688-272sk   0/1   Running   0
ticket-7bc5799688-cfjsw   0/1   Running   0
kubectl get endpoints ticket → (vide)
GET /api/tickets via Ingress → HTTP/1.1 503 Service Temporarily Unavailable
Events: Readiness probe failed: HTTP probe failed with statuscode: 503
```
Après `scale --replicas=2`, les Pods ticket repassent `1/1` d'eux-mêmes, sans intervention.

**Q6.1** (1) movie n'a plus de Pod ⇒ `MovieHealthIndicator` échoue (DNS/connexion) ⇒ readiness de ticket = `DOWN` (503). (2) Après 3 échecs consécutifs (3 × 5 s), le kubelet marque les Pods ticket `NotReady`. (3) Le contrôleur d'endpoints retire leurs IP du Service `ticket`, qui n'a plus d'endpoints. (4) L'Ingress nginx n'a plus de backend ⇒ `503`. `RESTARTS` reste à 0 car seule la readiness échoue ; la liveness (qui seule déclenche un redémarrage) reste `UP`.

### 6.2 Dépannage de `ticket-debug`

| # | Statut observé | Commande de diagnostic | Cause exacte | Correction |
|---|---|---|---|---|
| 1 | `ErrImagePull` → `ImagePullBackOff` | `kubectl describe pod` (Events) | `imagePullPolicy: Always` : tentative de pull de `ticket-service:1.0.0` sur docker.io (image locale seulement) | `imagePullPolicy: IfNotPresent` |
| 2 | `CreateContainerConfigError` | `kubectl describe pod` (`configmap "ticket-configmap" not found`) | `envFrom` référence une ConfigMap inexistante | `name: ticket-config` |
| 3 | `Running` mais `0/1` | `kubectl describe pod` (`Readiness probe failed … :8081 connection refused`), puis après correction du port de la probe : `connection refused` sur `:8080` | Port de la probe faux (8081), puis `containerPort: 8080` alors que l'appli écoute sur 8086 (le port nommé `http` pointait donc au mauvais endroit) | probe sur `port: http` **et** `containerPort: 8086` |

Résultat final : `ticket-debug` `1/1 Running`, puis `kubectl delete -f broken/ticket-debug.yaml`. Le fichier `broken/ticket-debug.yaml` contient les corrections.
Note : l'énoncé annonce 3 erreurs ; la 3e (port) se décompose en deux corrections (port de la probe, puis `containerPort`).

### 6.3
`MOVIE_ENVIRONMENT` passé à `production` dans `10-config.yaml` (le fichier reste à cette valeur) :
```
apply → whoami = "kubernetes"  (inchangé)
rollout restart → whoami = "production"
```
**Q6.3** Les variables d'environnement d'un conteneur sont figées à sa création ; modifier la ConfigMap ne touche pas les Pods déjà lancés. `rollout restart` recrée les Pods, qui relisent la ConfigMap.

## Partie 7
**Q7.1** Le client (JVM de ticket) demande `movie` au DNS du cluster (CoreDNS), via `/etc/resolv.conf` du Pod (domaines de recherche `cinema-exam.svc.cluster.local`…) ; il obtient la ClusterIP du Service `movie`. La requête part vers cette IP virtuelle : les règles de kube-proxy (iptables/ipvs) la redirigent (DNAT) vers l'IP:port d'un des Pods listés dans les endpoints, choisi au hasard/en tourniquet.

**Q7.2** Les tickets sont stockés en mémoire de chaque Pod ; le Service envoie chaque requête à un des 2 Pods, donc la liste (et son `length`) varie (observé : 2, 2, 2, 3, 3, 3 avec 4 tickets créés). Si on supprime les Pods, tout est perdu. Solution architecturale : externaliser l'état dans une base de données (ou un service de stockage) partagée, avec un volume persistant (StatefulSet / PVC) ou une base managée ; les Pods restent sans état.

**Q7.3** Le Pod supprimé est recréé immédiatement par le ReplicaSet (un nouveau Pod `0/1` puis `1/1` apparaît), l'application reste disponible grâce à l'autre réplica. Un `kind: Pod` nu aurait disparu définitivement : pas de recréation automatique, pas de réplicas, pas de rolling update ni de rollback.

## Bonus
### B1 — Durcissement de `movie`
`securityContext` du conteneur (`20-movie.yaml`) : `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `readOnlyRootFilesystem: true`. Comme Tomcat doit écrire dans `/tmp`, j'ai ajouté un volume `emptyDir` monté sur `/tmp`.
```
$ kubectl exec deploy/movie -- id
uid=10001(spring) gid=101(spring) groups=101(spring)
$ kubectl exec deploy/movie -- touch /test
touch: cannot touch '/test': Read-only file system
```
Les Pods sont `1/1`.

### B2 — Rolling update sans coupure
Ajout de `strategy: RollingUpdate` avec `maxUnavailable: 0` et `maxSurge: 1`. Pendant un `kubectl rollout restart deploy/movie`, 300 requêtes sur `/api/movies` :
```
    300 200
```
**QB2** Aucune erreur. `maxUnavailable: 0` + `maxSurge: 1` : un nouveau Pod est créé avant qu'un ancien soit retiré, il n'y a donc jamais moins de 2 Pods prêts. La `readinessProbe` n'ajoute le nouveau Pod au Service qu'une fois l'appli démarrée, et ne laisse l'ancien partir qu'à ce moment-là. `shutdown: graceful` laisse l'ancien Pod terminer ses requêtes en cours avant de s'arrêter.
