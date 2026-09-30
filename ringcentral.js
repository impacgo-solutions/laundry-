const { SDK } = require("@ringcentral/sdk");
const fs = require("fs");

async function rcLogin() {
  const config = JSON.parse(fs.readFileSync("./ringcentral_jwt.json", "utf8"));

  const jwt = config.jwt.IPGlaundryLTD; // MUST be a valid string

  const rcsdk = new SDK({
    server: "https://platform.ringcentral.com",
    clientId: config.clientId,
    clientSecret: config.clientSecret
  });

  const platform = rcsdk.platform();

  await platform.login({ jwt });

  return platform;
}

module.exports = { rcLogin };
