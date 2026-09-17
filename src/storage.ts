import type { WorldState } from "./simulation/types";
const open = () =>
  new Promise<IDBDatabase>((resolve, reject) => {
    const r = indexedDB.open("terrarium-observatory", 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore("worlds", { keyPath: "id" });
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
export async function saveLocal(w: WorldState) {
  const db = await open();
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction("worlds", "readwrite");
    tx.objectStore("worlds").put(w);
    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error);
    };
  });
}
export async function listLocal() {
  const db = await open();
  return new Promise<WorldState[]>((resolve, reject) => {
    const tx = db.transaction("worlds");
    const req = tx.objectStore("worlds").getAll();
    req.onsuccess = () => {
      db.close();
      resolve(
        (req.result as WorldState[]).sort((a, b) => b.createdAt - a.createdAt),
      );
    };
    req.onerror = () => {
      db.close();
      reject(req.error);
    };
  });
}
