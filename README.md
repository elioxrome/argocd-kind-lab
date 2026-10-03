# ArgoCD multi-instancia en kind (local)

Réplica local, como IaC, de la arquitectura de ArgoCD de la empresa: un
cluster de **management (hub)** que corre **una instancia de ArgoCD por
"tipo"** (IT4T, DIGITAL, EOP, PSC, BCC), y cada instancia gestiona su propio
**cluster de aplicaciones (spoke)**, salvo IT4T que despliega directo en el
hub. Todo con [kind](https://kind.sigs.k8s.io/) + [Helm](https://helm.sh/),
reproducible desde cero con dos scripts.

## Arquitectura

```
                         cluster "hub" (management)
                 ┌──────────────────────────────────────┐
                 │  argocd-it4t     (sin spoke propio,   │
                 │                   despliega en hub)   │
                 │  argocd-digital  ──────────┐          │
                 │  argocd-eop      ──────┐   │          │
                 │  argocd-psc      ──┐   │   │          │
                 │  argocd-bcc      ┐ │   │   │          │
                 └──────────────────┼─┼───┼───┼──────────┘
                                    │ │   │   │
                                    ▼ ▼   ▼   ▼
                                 bcc psc eop digital
                              (clusters spoke, uno por tipo)
```

- **hub**: cluster de management. Ahí viven *todas* las instancias de
  ArgoCD, cada una en su propio namespace `argocd-<tipo>`.
- **digital / eop / psc / bcc**: clusters spoke, uno por tipo, donde se
  despliegan las aplicaciones reales. Cada instancia de ArgoCD solo conoce y
  gestiona **su propio** spoke (mismo nombre que el tipo).
- **it4t**: es la excepción — no tiene spoke, sus Applications van directo
  al hub. Técnicamente también es la instancia "dueña" de los
  CustomResourceDefinitions de Argo (`applications.argoproj.io`, etc.), que
  son *cluster-scoped* y solo un release de Helm puede poseer (ver
  [Decisiones de diseño](#decisiones-de-diseño-y-limitaciones)).

Esto es una simplificación fiel del diagrama original: ahí también hay una
capa de alta disponibilidad/DR (clusters de management M1/M3 activo+réplica)
que aquí no se replica porque no tiene sentido en un kind local.

## Requisitos

- `docker`
- `kind`
- `kubectl`
- `helm`

## Estructura del repo

```
kind/                           # 1 archivo = 1 cluster kind
  hub.yaml                      # cluster de management
  digital.yaml                  # spoke del tipo "digital"
  delete/                       # spokes desactivados temporalmente
    eop.yaml, psc.yaml, bcc.yaml  # (ver "Escalar a más tipos")

up.sh                           # crea los clusters kind + acceso hub->spoke
down.sh                         # borra todos los clusters kind

argocd/
  base-values.yaml              # config Helm común a todas las instancias
  instances/<tipo>/values.yaml  # overrides propios de cada instancia
  install.sh                    # helm upgrade --install por tipo, en el hub
  register-clusters.sh          # registra un spoke dentro de su instancia
  port-forward.sh               # expone la UI de una instancia en localhost
  admin-password.sh             # imprime el password inicial de admin
  status.sh                     # resumen de qué instancias están arriba
  applicationsets/
    digital-guestbook-appset.yaml  # ejemplo de app-of-apps / ApplicationSet
```

Nada de ArgoCD queda hardcodeado en `up.sh`: ese script solo levanta
infraestructura de kind y prepara el acceso de red/RBAC entre clusters. Todo
lo de ArgoCD (qué instancias existen, sus recursos, sus clusters
registrados) vive en `argocd/` como config declarativa.

## Quickstart (estado actual: solo it4t + digital)

```bash
./up.sh                              # crea hub + spoke "digital"
./argocd/install.sh                  # instala argocd-it4t y argocd-digital en el hub
./argocd/register-clusters.sh digital  # registra el spoke "digital" en su propia instancia

./argocd/status.sh                   # ver que todo esté arriba
```

### Ver cada ArgoCD

Cada instancia es independiente; no hay una UI combinada. Para verlas,
usa un puerto local distinto por cada una (en terminales/pestañas separadas):

```bash
./argocd/port-forward.sh it4t 8443      # https://localhost:8443
./argocd/port-forward.sh digital 8444   # https://localhost:8444
```

Usuario `admin` en ambas, password con:

```bash
./argocd/admin-password.sh it4t
./argocd/admin-password.sh digital
```

### Probar que el flujo GitOps funciona de verdad

```bash
kubectl --context kind-hub -n argocd-digital apply \
  -f argocd/applicationsets/digital-guestbook-appset.yaml

kubectl --context kind-hub -n argocd-digital get applications
# debería verse "guestbook-digital"  Synced  Healthy

kubectl --context kind-digital -n guestbook get pods
# el pod corre en el cluster "digital" de verdad, no en el hub
```

El ApplicationSet usa el generador `clusters` built-in de Argo: enumera los
Secrets de tipo `cluster` registrados en el namespace de la instancia
(`role: spoke`) y despliega una Application por cada uno. `repoURL` apunta
al repo público de ejemplo de Argo (`argocd-example-apps`) — sustitúyelo por
tu propio repo de aplicaciones cuando quieras desplegar algo real.

### Ver qué namespace/instancia tiene cada cosa

No hay un único panel: cada Application vive en el namespace de la instancia
que la gestiona (`argocd-<tipo>`), y esa instancia solo ve los clusters que
tú registraste dentro de *ese mismo* namespace.

```bash
./argocd/status.sh digital           # pods de esa instancia
kubectl --context kind-hub -n argocd-digital get applications
```

## Apagar todo

```bash
./down.sh
```

Borra los clusters kind que estén levantados. No hay estado que
"desinstalar" aparte — al borrar el cluster se va todo (ArgoCD, Applications,
todo).

## Escalar a más tipos (eop, psc, bcc)

Los overrides de Helm de esas 3 instancias ya existen en
`argocd/instances/{eop,psc,bcc}/`, pero sus clusters kind están desactivados
(movidos a `kind/delete/`) para no gastar RAM mientras se prueba solo
it4t+digital. Para reactivar uno:

```bash
mv kind/delete/eop.yaml kind/eop.yaml

./up.sh digital eop                      # suma el spoke "eop" (mantiene "digital")
./argocd/install.sh it4t digital eop     # suma la instancia argocd-eop
./argocd/register-clusters.sh eop
```

`up.sh` e `install.sh` aceptan la lista de tipos como argumentos; sin
argumentos usan el default reducido (`digital` / `it4t digital`).

## Decisiones de diseño y limitaciones

- **Chart**: `argo-cd` oficial de [argo-helm](https://github.com/argoproj/argo-helm),
  fijado en la versión `10.9.6` (appVersion ArgoCD `v3.5.3`) para que la
  instalación sea reproducible — no se usa `helm repo add`, `install.sh`
  apunta directo al repo con `--repo`.
- **Recursos recortados**: en el diagrama original cada instancia pide
  0.5–2 vCPU / 1–4 GiB por componente, pensado para OpenShift real. Acá se
  recortan los `requests`/`limits` en `base-values.yaml` para que varias
  instancias quepan en un laptop corriendo kind.
- **Redis**: se mantiene el Redis embebido de una sola réplica que trae el
  propio chart (lo necesitan `repo-server` y `application-controller` para
  cache interna, no es opcional). No hay `redis-ha` ni Redis externo.
- **`server.insecure: true`**: kind no termina TLS delante del `Service` de
  ArgoCD, así que el server sirve HTTP plano puertas adentro; el acceso
  real sigue siendo vía `kubectl port-forward` con HTTPS.
- **CRDs cluster-scoped**: los CRDs de Argo (`applications.argoproj.io`,
  `appprojects.argoproj.io`, `applicationsets.argoproj.io`) no son
  namespaced, así que solo **un** release de Helm puede administrarlos sin
  pelear por la propiedad. `it4t` lleva `crds.install: true`; el resto
  (`digital/eop/psc/bcc`) lleva `crds.install: false` y por eso necesitan
  que `it4t` ya exista antes de instalarse.
- **Acceso hub → spoke**: `up.sh` crea en cada spoke un `ServiceAccount`
  `argocd-manager` con `cluster-admin` y genera su token en
  `.generated/cluster-<tipo>.yaml` (gitignored). `register-clusters.sh`
  aplica ese Secret dentro del namespace de la instancia que vas a usar —
  sin eso, el `ApplicationSet` no encuentra clusters y genera 0 Applications
  (fue justo el primer problema que nos pasó probando esto).

## Troubleshooting rápido

**El ApplicationSet generó 0 Applications / `get applications` no muestra nada:**
falta registrar el cluster. Verifica:
```bash
kubectl --context kind-hub -n argocd-<tipo> get secrets -l argocd.argoproj.io/secret-type=cluster
```
Si no hay nada, corre `./argocd/register-clusters.sh <tipo>`.

**`helm upgrade --install` de una instancia nueva falla con error de
"invalid ownership metadata" sobre un CRD:** le falta `crds.install: false`
en su `values.yaml` (ver [Decisiones de diseño](#decisiones-de-diseño-y-limitaciones)).

**`kind get clusters` no muestra nada aunque ya los habías creado:** si
corriste `up.sh` desde un entorno distinto al de tu terminal (p. ej. un
sandbox efímero), los clusters de Docker viven ahí y no en tu máquina real.
Corre `up.sh`/`install.sh`/`register-clusters.sh` en la misma terminal
donde vayas a trabajar.
