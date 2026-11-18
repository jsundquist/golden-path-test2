const http = require("http");

http
  .createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    res.end(String(eval(url.searchParams.get("expr"))));
  })
  .listen(8080);
