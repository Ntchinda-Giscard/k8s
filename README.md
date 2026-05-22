# ☸️ Wazalink Kubernetes Deployment Guide

This directory contains the production-grade Kubernetes manifest files and deployment procedures for the **Wazalink** integration project.

---

## 📂 Manifests Breakdown

1. **`configmap.yaml`**: Contains non-sensitive application environment variables such as Sage database hosts, port configurations, Syracuse Web Service base URL, etc.
2. **`secret.yaml`**: Holds sensitive credentials (passwords and usernames) for Syracuse SOAP interface and SQL Server connections, using the convenient `stringData` layout.
3. **`pvc.yaml`**: Requests a persistent volume (`1Gi`) for SQLite state persistence. This maps directly to the container home directory `/root/wazalink_data` inside the pod.
4. **`deployment.yaml`**: Specifies a 1-replica application template running the custom FastAPI Docker image. Configured with a `Recreate` strategy to ensure zero file locking contentions on the database.
5. **`service.yaml`**: Exposes the application on a cluster-internal stable IP address on port `80` (routing internally to target port `8080`).

---

## 🛠️ Step 1: Building the Docker Image

To build the Docker image supporting Microsoft SQL Server ODBC drivers, run the following docker command from the **repository root directory** (where the `Dockerfile` resides):

```bash
docker build -t <your-registry>/wazalink:latest .
```

*Note: The Dockerfile uses a Debian-slim base image and automatically registers Microsoft package signatures to install `msodbcsql17` and `msodbcsql18` packages. This ensures Python `pyodbc` works perfectly on Linux containers.*

Push the image to your container registry:
```bash
docker push <your-registry>/wazalink:latest
```

---

## 🚀 Step 2: Deploying to Kubernetes

1. **Verify or Edit Configurations**:
   - Open `configmap.yaml` and update the Syracuse endpoints or Sage host names as required.
   - Open `secret.yaml` and replace the placeholder credentials with actual production secrets.

2. **Apply all Manifests to the Cluster**:
   You can apply all configuration resources collectively by targeting this directory:
   ```bash
   kubectl apply -f k8s/
   ```

3. **Monitor the Rollout Status**:
   ```bash
   kubectl get pods -l app=wazalink -w
   ```

---

## 🔍 Step 3: Verifying the Deployment

The deployment includes auto-configured `readinessProbe` and `livenessProbe` health checks. 

To test connectivity internally, run a port-forward command to route traffic from your local workstation:
```bash
kubectl port-forward svc/wazalink-service 8080:80
```

Now, visit `http://localhost:8080` in your web browser. You should receive:
```json
{
  "Health": "The endpoint is up and running."
}
```

---

## ⚙️ Scaling and Centralized State Considerations

> [!WARNING]
> Because SQLite relies on local file locks, running multiple replicas of the container sharing the same Persistent Volume will cause locking errors.
> If you plan to scale the Wazalink pod to `2` or more replicas for high availability:
> 1. You should migrate the internal SQLite database state (`session.py`) to a centralized client-server engine like **PostgreSQL** or **MS SQL Server**.
> 2. Once done, you can delete the `pvc.yaml` manifest, remove the `volumeMounts` configuration from `deployment.yaml`, and safely adjust `replicas` to any desired count.
