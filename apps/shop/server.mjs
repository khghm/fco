import { createServer } from "node:http";
import next from "next";

if (process.argv.includes("--prod")) {
  process.env.NODE_ENV = "production";
}

const dev = process.argv.includes("--dev") || process.env.NODE_ENV !== "production";
const port = Number(process.env.PORT ?? "3000");
const hostname = process.env.FCO_HOST ?? "0.0.0.0";

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("PORT must be an integer between 1 and 65535.");
}

const app = next({ dev, hostname, port });
await app.prepare();
const handle = app.getRequestHandler();

const server = createServer((request, response) => {
  const remoteAddress = request.socket.remoteAddress;
  if (remoteAddress) {
    request.headers["x-fco-remote-address"] = remoteAddress;
  } else {
    delete request.headers["x-fco-remote-address"];
  }

  void handle(request, response).catch((error) => {
    console.error("Next.js request handler failed.", error);
    if (response.headersSent) {
      response.destroy(error instanceof Error ? error : undefined);
      return;
    }
    response.statusCode = 500;
    response.end("Internal server error.");
  });
});

server.on("error", (error) => {
  console.error("Storefront server failed to start or stopped unexpectedly.", error);
  process.exitCode = 1;
});

server.listen(port, hostname, () => {
  console.log(`Storefront listening on http://${hostname}:${port}`);
});
