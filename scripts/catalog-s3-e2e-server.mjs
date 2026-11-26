import S3rver from "s3rver";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const port = Number(process.env.S3_E2E_PORT ?? "19000");
const bucket = process.env.S3_BUCKET ?? "fco-catalog-e2e";
const directory = mkdtempSync(join(tmpdir(), "fco-s3rver-"));
const server = new S3rver({
  address: "127.0.0.1",
  port,
  silent: true,
  directory,
  resetOnClose: true,
  configureBuckets: [{ name: bucket }],
});

await server.run();
console.log(`S3rver listening on 127.0.0.1:${port}`);

let closing = false;
async function close() {
  if (closing) {
    return;
  }
  closing = true;
  await server.close();
  rmSync(directory, { recursive: true, force: true });
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    void close().then(
      () => process.exit(0),
      (error) => {
        console.error("Could not stop the temporary S3 E2E server.", error);
        process.exit(1);
      },
    );
  });
}
