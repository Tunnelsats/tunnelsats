const express = require("express");
const path = require("path");
const bodyParser = require("body-parser");
const axios = require("axios");
const nodemailer = require("nodemailer");
const dayjs = require("dayjs");
const utc = require("dayjs/plugin/utc");
dayjs.extend(utc);

const lightningPayReq = require("bolt11");

const { SocksProxyAgent } = require("socks-proxy-agent");
const fetch = require("node-fetch-commonjs");
const { logDim } = require("./logger");
require("dotenv").config();

DEBUG = true;

// This array saves all invoices and wg keys (received by the client connection)
// As soon as the invoice is paid the server sends the config information to the related client
// This prevents sending all information to all clients and only sends a valid wg config to the related client
// The socket is still open for all clients to connect to

let invoiceWGKeysMap = [];

// Restrict entries to prevent an attack to fill the ram memory
const MAXINVOICES = 100;

// 60 minutes after the invoice is in memory it is purged after any user disconnects
// unit is milliseconds
const TIMERCLEANINGINVOICEDATA = 60 * 60000;
const app = express();

// helper
const getDate = (timestamp) =>
  (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString();
function isEmpty(obj) {
  return Object.keys(obj).length === 0;
}

// Telegram Settings
const TELEGRAM_CHATID = import.meta.env.TELEGRAM_CHATID || "";
const TELEGRAM_TOKEN = import.meta.env.TELEGRAM_TOKEN || "";
const TELEGRAM_PREFIX = import.meta.env.TELEGRAM_PREFIX || "";

// Tor Proxy for Telegram Bot
const TELEGRAM_PROXY_HOST = import.meta.env.TELEGRAM_PROXY_HOST || "";
const TELEGRAM_PROXY_PORT = import.meta.env.TELEGRAM_PROXY_PORT || "";

// Env Variables to have the same code base main and dev
const VITE_ONE_MONTH = import.meta.env.VITE_ONE_MONTH || 3.0;
const VITE_THREE_MONTHS = import.meta.env.VITE_THREE_MONTHS || 8.5;
const VITE_SIX_MONTHS = import.meta.env.VITE_SIX_MONTHS || 16.0;
const VITE_ONE_YEAR = import.meta.env.VITE_ONE_YEAR || 28.5;

// fetch latest git commit hash
const URL_GIT_COMMIT_HASH = import.meta.env.URL_GIT_COMMIT_HASH || "";

// This map is needed to verify that the client does not cheat us
// and sends us the wrong pricing
// client sends us the selection and the price we verify and only
// allow invoice creation if the client behaves corrently
const PRICESUBSCRIBTIONMAP = [
  VITE_ONE_MONTH,
  VITE_THREE_MONTHS,
  VITE_SIX_MONTHS,
  VITE_ONE_YEAR,
];

// In case we have a discount period we need to account for it
// on the server side
//const VITE_DISCOUNT = parseFloat(import.meta.env.VITE_DISCOUNT);

// Cleaning Ram from old PaymentRequest data

const intervalId = setInterval(function () {
  DEBUG && logDim("Cleaning Invoice Data Periodically");
  let index = 0;

  const currentTime = Date.now();

  // Delete all user related information
  while (index !== -1) {
    index = invoiceWGKeysMap.findIndex((client) => {
      // console.log(currentTime - client.timestamp);
      // Timeinterval in which Invoice Related Date is purged from the memory
      // in milliseconds
      const invoiceExpiry =
        lightningPayReq.decode(client.paymentDetails.payment_request)
          .timeExpireDate * 1000;
      // Remove Invoice as soon as it is expired
      return currentTime - invoiceExpiry > 0;
    });
    if (index !== -1) {
      invoiceWGKeysMap.splice(index, 1);
    }
  }
}, TIMERCLEANINGINVOICEDATA);

// Telegram Bot

// token looks like adsfasfdsf:adsfsadfasdfasfasdfasfd-asdfsf
// chat_id looks like 1231231231
const sayWithTelegram = async ({ message, parse_mode = "HTML" }) => {
  // parse_mode can be undefined, or 'MarkdownV2' or 'HTML'
  // https://core.telegram.org/bots/api#html-style
  let proxy = "";
  if (TELEGRAM_PROXY_HOST != "" && TELEGRAM_PROXY_PORT != "") {
    proxy = `socks://${TELEGRAM_PROXY_HOST}:${TELEGRAM_PROXY_PORT}`;
  }

  message = `[${TELEGRAM_PREFIX}] ` + message;

  const parseModeString = parse_mode ? `&parse_mode=${parse_mode}` : "";
  try {
    let endpoint = `https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage?chat_id=${TELEGRAM_CHATID}&text=${encodeURIComponent(
      message
    )}${parseModeString}`;
    let opts = new URL(endpoint);
    if (proxy === "") {
      logDim(`sayWithTelegram(${message})`);
    } else {
      opts.agent = new SocksProxyAgent(proxy);
    }

    const res = await fetch(opts);
    const fullResponse = await res.json();
    // logDim(`${getDate()} sayWithTelegramBot() result:`, JSON.stringify(fullResponse, null, 2))
    return fullResponse;
  } catch (e) {
    logDim(`sayWithTelegram() aborted:`, e);
    return null;
  }
};

// Server Settings
const createServer = require("http");
const { response } = require("express");
// const { rootCertificates } = require('tls');
const httpServer = createServer.createServer(app);
const io = require("socket.io")(httpServer, {
  cors: {
    // restrict to SOP (Same Origin Policy)
    origin: false,
  },
});

// Set up the Webserver
app.use(express.static(path.join(__dirname, "../client/build")));
app.use(bodyParser.json());

// Serving the index site
app.get("/", function (req, res) {
  res.sendFile(path.join(__dirname, "../client/build", "index.html"));
});

// Invoice Webhook for Lnbits
// This API endpoint is called after an invoice is paid
app.post(import.meta.env.WEBHOOK, (req, res) => {
  const index = invoiceWGKeysMap.findIndex((client) => {
    return client.paymentDetails.payment_hash === req.body.payment_hash;
  });

  if (index !== -1) {
    const {
      paymentDetails,
      publicKey,
      presharedKey,
      priceDollar,
      country,
      id,
      amountSats,
    } = invoiceWGKeysMap[index];

    checkInvoice(paymentDetails.payment_hash).then((result) => {
      if (!!result) {
        invoiceWGKeysMap[index].isPaid = true;

        // Needed for now to notify the client to stop the spinner
        io.to(id).emit("invoicePaid", paymentDetails.payment_hash);

        // Looks through the invoice map saved into ram and
        // sends the config ONLY to the relevant client
        getWireguardConfig(
          publicKey,
          presharedKey,
          getTimeStamp(priceDollar),
          getServer(country)
        )
          .then((result) => {
            io.to(id).emit("receiveConfigData", result);
            logDim(`Successfully created wg entry for pubkey ${publicKey}`);

            invoiceWGKeysMap[index].resultBackend = result;

            const serverDNS = getServer(country)
              .replace(/^https?:\/\//, "")
              .replace(/\/manager\/$/, "");
            sayWithTelegram({
              // prettier-ignore
              message: `🟢 New Subscription: 🍾\n Price: ${priceDollar}\$\n ServerLocation: ${serverDNS}\n Sats: ${Math.round(amountSats)}💰`,
            })
              .then((result) => {
                DEBUG &&
                  logDim(`getWireguardConfig(): ${JSON.stringify(result)}`);
              })
              .catch((error) => logDim(error.message));

            res.status(200).end();
          })
          .catch((error) => {
            DEBUG && logDim(`getWireguardConfig(): ${error.message}`);
            sayWithTelegram({
              message: `🔴 Creating New Subscription failed with ${error.message}`,
            });
            res.status(500).end();
          });
      } else {
        logDim(`Invoice not Paid Invoice: ${paymentDetails.payment_hash}`);
      }
    });
  } else {
    logDim(`No Invoice and corresponding connection found in memory`);
    logDim(`Probably Server crashed and lost invoice memory`);

    res.status(500).end();
  }
});

// Webhook for updating the Subcription
// Invoice Webhook
app.post(import.meta.env.WEBHOOK_UPDATE_SUB, (req, res) => {
  const index = invoiceWGKeysMap.findIndex((client) => {
    return client.paymentDetails.payment_hash === req.body.payment_hash;
  });

  if (index !== -1) {
    const {
      paymentDetails,
      keyID,
      priceDollar,
      serverURL,
      id,
      publicKey,
      amountSats,
    } = invoiceWGKeysMap[index];

    invoiceWGKeysMap[index].isPaid = true;

    checkInvoice(paymentDetails.payment_hash).then((result) => {
      if (!!result) {
        // Needed for now to notify the client to stop the spinner
        io.to(id).emit(
          "invoicePaidUpdateSubscription",
          paymentDetails.payment_hash
        );

        getSubscription({
          keyID,
          serverURL,
        })
          .then((result) => {
            console.log(result.subscriptionEnd);
            newSubscriptionEnd({
              keyID,
              subExpiry: getTimeStamp(
                priceDollar,
                parseBackendDate(result.subscriptionEnd)
              ),
              serverURL,
              publicKey,
            })
              .then((result) => {
                io.to(id).emit("receiveUpdateSubscription", result);
                logDim(
                  `Successfully updated new SubscriptionEnd for  ${publicKey}`
                );

                invoiceWGKeysMap[index].resultBackend = result;

                sayWithTelegram({
                  // prettier-ignore
                  message: `🟢 Renewed Subscription: 🍾\n Price: ${priceDollar}\$\n PubKey: ${publicKey} \n ServerLocation: ${serverURL}\n Sats: ${Math.round(amountSats)}💰`,
                })
                  .then((result) => {
                    DEBUG &&
                      logDim(`getSubscription(): ${JSON.stringify(result)}`);
                  })
                  .catch((error) => logDim(error.message));
                res.status(200).end();
              })
              .catch((error) => {
                logDim("newSubscriptionEnd() ", error.message);
                res.status(500).end();
              });
          })
          .catch((error) => {
            logDim("getSubscription() ", error.message);
            res.status(500).end();
          });
      } else {
        logDim(`Invoice not Paid Invoice: ${paymentDetails.payment_hash}`);
      }
    });
  }
});

httpServer.listen(import.meta.env.PORT, "0.0.0.0");
console.log(`${getDate()} httpServer listening on port ${import.meta.env.PORT}`);

// Socket Connections
io.on("connection", (socket) => {
  console.log(`${getDate()} ${socket.id} io.socket: connected`);

  // Checks for a paid Invoice after reconnection of the client
  // To allow for recovery in calse the client looses connection but pays the invoice
  socket.on("checkInvoice", (clientPaymentHash) => {
    DEBUG &&
      logDim(`checkInvoice() called: ${socket.id}, hash: ${clientPaymentHash}`);
    checkInvoice(clientPaymentHash)
      .then((result) => {
        const index = invoiceWGKeysMap.findIndex((client) => {
          return client.paymentDetails.payment_hash === result;
        });

        if (index !== -1) {
          const { paymentDetails, publicKey, isPaid, resultBackend, tag } =
            invoiceWGKeysMap[index];

          if (isPaid) {
            io.to(socket.id).emit("invoicePaid", paymentDetails.payment_hash);

            if (tag === "New Subscription") {
              io.to(socket.id).emit("receiveConfigData", resultBackend);
              logDim(
                `Resend wg credentials to already paid invoice entry for pubkey ${publicKey}`
              );
            }

            if (tag === "Update Subscription") {
              io.to(socket.id).emit("receiveUpdateSubscription", resultBackend);
              logDim(`Resend new subscription expiry date`);
            }
          }
        } else {
          logDim(
            `No Invoice and corresponding connection found in memory ${socket.id}`
          );
        }
      })
      .catch((error) => {
        logDim(`${error.message}`);
        logDim(
          `no way to recover this state in a secure manner | server crashed potentially`
        );
      });
  });

  // Getting the Invoice from lnbits and forwarding it to the frontend
  socket.on("getInvoice", async (payload) => {
    DEBUG &&
      logDim(`getInvoice() called by socket id: ${socket.id} with payload
      ${JSON.stringify(payload, null, 4)}`);

    if (
      // We need all of those from the client otherwise we do nothing
      !!payload.selection &&
      !!payload.publicKey &&
      !!payload.country
    ) {
      if (invoiceWGKeysMap.length <= MAXINVOICES) {
        const satsPerDollar = await getPrice();

        try {
          if (
            payload.selection > PRICESUBSCRIBTIONMAP.length ||
            payload.selection < 0
          ) {
            logDim(
              `Error - potential malicous behaviour by the peer received selection is ${payload.selection}`
            );
            return;
          }
          const priceDollar = PRICESUBSCRIBTIONMAP[payload.selection - 1];
          const priceSats = Math.round(satsPerDollar * priceDollar);
          let paymentDetails;

          if (payload.isRenew) {
            if (payload.keyID != 0) {
              paymentDetails = await getInvoice(
                priceSats,
                priceDollar,
                import.meta.env.URL_WEBHOOK_UPDATE_SUB
              );
            } else {
              logDim(`Error - keyID is not valid ${payload.keyID}`);
              return;
            }
          } else {
            // We check here because renew does not need a preshared key
            if (!!payload.presharedKey) {
              paymentDetails = await getInvoice(
                priceSats,
                priceDollar,
                import.meta.env.URL_WEBHOOK
              );
            }
          }

          let serverURL = getServer(payload.country);
          if (!!serverURL) {
            serverURL = serverURL
              .replace(/^https?:\/\//, "")
              .replace(/\/manager\/$/, "");
          } else {
            // report to system
            logDim(`Error - no valid serverURL for ${payload.country}`);
            sayWithTelegram({
              // prettier-ignore
              message: `❗️ Failed to generate invoice: no valid server url for country: ${payload.country}, url: ${serverURL}`,
            });

            //also report to frontend
            socket.emit("error", "Error fetching server details!");

            return;
          }

          socket.emit("lnbitsInvoice", paymentDetails);
          // Safes the client request related to the socket id including
          // the payment_hash to later send the config data only to the right client
          invoiceWGKeysMap.push({
            paymentDetails: paymentDetails,
            publicKey: payload.publicKey,
            presharedKey: payload.presharedKey,
            priceDollar: priceDollar,
            country: payload.country,
            keyID: payload.keyID,
            serverURL: serverURL,
            id: socket.id,
            amountSats: priceSats,
            timestamp: Date.now(),
            isPaid: false,
            tag: payload.isRenew ? "Update Subscription" : "New Subscription",
          });

          DEBUG && console.log(invoiceWGKeysMap);
        } catch (error) {
          logDim(error.message);
        }
      } else {
        logDim(
          `restrict overall invoices to ${MAXINVOICES} to prevent mem overflow `
        );
      }
    }
  });

  // New Listening events for UpdateSubscription Request

socket.on("checkKeyDB", async ({ publicKey }) => {
  console.log(`server: checkKeyDB with key ${publicKey}`);

  let keyID;
  let subscriptionEnd;
  let success = false;
  const servers = [
    { domain: "de1.tunnelsats.com", country: "eu" },
    { domain: "de3.tunnelsats.com", country: "eu2" },
    { domain: "de2.tunnelsats.com", country: "eu3" },
    { domain: "us2.tunnelsats.com", country: "na2" }, // us west
    { domain: "us3.tunnelsats.com", country: "na3" }, // us east
    { domain: "us1.tunnelsats.com", country: "na" }, // us east
    { domain: "sg1.tunnelsats.com", country: "as" },
    { domain: "br1.tunnelsats.com", country: "sa" },
    { domain: "au1.tunnelsats.com", country: "oc" },
    //{ domain: "za1.tunnelsats.com", country: "af" },      
  ];

  for (const serverURL of servers) {
    if (success) break;

    console.log(`server: CheckKeyDB server: ${serverURL.domain}`);
    let country = serverURL.country;
    let domain = serverURL.domain;

    try {
      const keyResult = await getKey({ publicKey, serverURL: domain });
      keyID = keyResult.KeyID;

      const subResult = await getSubscription({
        keyID: keyResult.KeyID,
        serverURL: domain,
      });

      console.log(subResult);
      let unixTimestamp = parseBackendDate(subResult.subscriptionEnd);
      let date = new Date(unixTimestamp);
      logDim("SubscriptionEnd: ", date.toISOString());
      subscriptionEnd = date;

      // Special handling for us3: check us1 too
      if (domain.includes("us3")) {
        const us1Domain = "us1.tunnelsats.com";

        try {
          const us1KeyResult = await getKey({ publicKey, serverURL: us1Domain });

          // If key in us3 and not in us1, renew us3
          if (!us1KeyResult) {
            socket.emit("receiveKeyLookup", {
              keyID,
              subscriptionEnd,
              domain,
              country,
            });
            success = true;
          } else {
            // Key in us3 and in us1, display popup "phase out"
            socket.emit("receiveKeyLookup", "not-allowed");
            success = true;
          }
        } catch (us1Error) {
          logDim(`us1 check failed: ${us1Error.message}`);
          // Us1 check failed: emit error
          socket.emit("error", "Error checking servers. Please try again later.");
          success = true;
        }
      } else {
        // Non-us3 servers: emit normally
        socket.emit("receiveKeyLookup", {
          keyID,
          subscriptionEnd,
          domain,
          country,
        });
        success = true;
      }
    } catch (error) {
      logDim(`getKey or getSubscription: ${error.message}`);
      // Continue to next server
    }
  }

  if (!success) {
    console.log(`emitting 'receiveKeyLookup': no key found`);
    socket.emit("receiveKeyLookup", null);
  }
});

  // send mail
  socket.on("sendEmail", (emailAddress, configData, date) => {
    sendEmail(emailAddress, configData, date).then((result) =>
      console.log(result)
    );
  });

  // getPrice
  socket.on("getPrice", () => {
    logDim(`getPrice() id: ${socket.id}`);
    getPrice()
      .then((result) => {
        io.to(socket.id).emit("receivePrice", result);
        logDim(`getPrice result: ${result}`);
      })
      .catch((error) => {
        return error;
      });
  });

  // getCommitHash
  socket.on("getCommitHash", () => {
    logDim(`getCommitHash() id: ${socket.id}`);
    getCommitHash()
      .then((result) => {
        io.to(socket.id).emit("receiveCommitHash", result);
        logDim(`getCommitHash() result: ${result}`);
      })
      .catch((error) => {
        return error;
      });
  });

  // getNodeStats
  socket.on("getNodeStats", () => {
    logDim(`getNodeStats() id: ${socket.id}`);
    getNodeStats()
      .then((result) => {
        io.to(socket.id).emit("receiveNodeStats", result);
        logDim(`getNodeStats() result: ${result}`);
      })
      .catch((error) => {
        return error;
      });
  });

  // disconnect
  socket.on("disconnect", () => {
    console.log(`User disconnected with ID: ${socket.id} `);
  });
});

// Transforms country into server
const getServer = (country) => {
  let server;

  switch (country) {
    case "eu":
      server = import.meta.env.IP_EU;
      break;
    case "eu2":
      server = import.meta.env.IP_EU2;
      break;
    case "eu3":
      server = import.meta.env.IP_EU3;
      break;
    case "na":
      server = import.meta.env.IP_USA;
      break;
    case "na2":
      server = import.meta.env.IP_USA2;
      break;
    case "na3":
      server = import.meta.env.IP_USA3;
      break;
    case "sa":
      server = import.meta.env.IP_LATAM;
      break;
    case "as":
      server = import.meta.env.IP_ASIA;
      break;
    case "oc":
      server = import.meta.env.IP_OCEANIA;
      break;
    default:
      server = "";
  }

  return server;
};

// Transforms duration into timestamp
const getTimeStamp = (selectedValue, offset) => {
  let date = new Date();
  if (offset && Date.now() < Date.parse(offset)) {
    date = new Date(offset);
  }

  if (selectedValue == VITE_ONE_MONTH) {
    date = addMonths(date, 1);
    return date;
  }

  if (selectedValue == VITE_THREE_MONTHS) {
    date = addMonths(date, 3);
    return date;
  }

  if (selectedValue == VITE_SIX_MONTHS) {
    date = addMonths(date, 6);
    return date;
  }

  if (selectedValue == VITE_ONE_YEAR) {
    date = addMonths(date, 12);
    return date;
  }

  function addMonths(date = new Date(), months) {
    var d = date.getUTCDate();
    date.setUTCMonth(date.getUTCMonth() + +months);
    if (date.getUTCDate() !== d) {
      date.setUTCDate(0);
    }
    return date;
  }
};

// Parse Date object to string format: YYYY-MMM-DD hh:mm:ss A
const parseBackendDate = (date) => {
  return dayjs.utc(date + "-00:00	").format("YYYY-MMM-DD hh:mm:ss AZ");
};

const parseDate = (date) => {
  return dayjs.utc(date).format("YYYY-MMM-DD hh:mm:ss A");
};

// API Calls using Axios

// Get Invoice Function
async function getInvoice(amount, priceDollar, webhook) {
  return axios({
    method: "post",
    url: import.meta.env.URL_INVOICE_API,
    headers: { "X-Api-Key": import.meta.env.INVOICE_KEY },
    data: {
      out: false,
      amount: amount,
      memo: getTimeStamp(priceDollar),
      webhook: webhook,
    },
  })
    .then(function (response) {
      if (response) {
        const payment_request = response.data.payment_request;
        const payment_hash = response.data.payment_hash;
        return { payment_hash, payment_request };
      }
    })
    .catch((error) => {
      throw new Error(
        `Error - not able to get Invoice from lnbits \n ${error.message}`
      );
    });
}

// Get Bitcoin Price in Satoshi per Dollar
async function getPrice() {
  return axios({
    method: "get",
    url: import.meta.env.URL_PRICE_API,
  })
    .then(function (response) {
      if (!isEmpty(response.data)) {
        return 100_000_000 / response.data.USD.buy;
      }
    })
    .catch((error) => {
      logDim(`Error - getPrice() ${error}`);
      return null;
    });
}

// fetch node stats
async function getNodeStats() {
  return axios({
    method: "get",
    url: "https://mempool.space/api/v1/lightning/statistics/latest",
  })
    .then(function (response) {
      if (!isEmpty(response.data)) {
        //logDim(`getNodeStats() response: ${response.data.latest}`);
        return response.data.latest;
      }
    })
    .catch((error) => {
      return error;
    });
}

// Get latest commit hash
async function getCommitHash() {
  return axios({
    method: "get",
    url: URL_GIT_COMMIT_HASH,
    headers: {
      Accept: "application/vnd.github.VERSION.sha",
    },
  })
    .then(function (response) {
      if (!isEmpty(response.data)) {
        //logDim(`getCommitHash(): result ${response.data}`)
        return response.data;
      }
    })
    .catch((error) => {
      logDim(`Error - getCommitHash() ${error}`);
      return null;
    });
}

// Get Wireguard Config
async function getWireguardConfig(publicKey, presharedKey, timestamp, server) {
  const serverURL = server
    .replace(/^https?:\/\//, "")
    .replace(/\/manager\/$/, "");

  const auth = getAuth(serverURL);

  const request1 = {
    method: "post",
    url: server + "key",
    headers: {
      "Content-Type": "application/json",
      Authorization: auth,
    },
    data: {
      publicKey: publicKey,
      presharedKey: presharedKey,
      bwLimit: 100000, // 100GB
      subExpiry: parseDate(timestamp),
      ipIndex: 0,
    },
  };

  const response1 = await axios(request1).catch((error) => {
    throw new Error(
      `Error - wgAPI createKey\n ${error.message}: ${error?.response?.data}`
    );
  });

  if (!isEmpty(response1.data)) {
    const request2 = {
      method: "post",
      url: server + "portFwd",
      headers: {
        "Content-Type": "application/json",
        Authorization: auth,
      },
      data: {
        keyID: response1.data.keyID,
      },
    };

    const response2 = await axios(request2).catch((error) => {
      throw new Error(
        `Error - wgAPI portFwd\n ${error.message}: ${error?.response?.data}`
      );
    });

    if (!isEmpty(response2.data)) {
      response1.data["portFwd"] = response2.data.portFwd;
      response1.data["dnsName"] = server
        .replace(/^https?:\/\//, "")
        .replace(/\/manager\/$/, "");
      return response1.data;
    }
  }
}

// Send Wireguard config file via email
async function sendEmail(emailAddress, configData, date) {
  const msg = {
    to: emailAddress,
    from: "payment@tunnelsats.com",
    subject: `Your Tunnel Sats VPN config file for Wireguard`,
    text: `Thank you for using Tunnel Sats!\n\nFind your personal config file attached. Don't lose it!\n\nFind your expiration date and wireguard public key within the config file (#ValidUntil).`,
    attachments: [
      {
        content: configData,
        filename: "tunnelsatsv2.conf",
        contentType: "text/plain",
        endings: "native",
        disposition: "attachment",
      },
    ],
  };

  const transporter = nodemailer.createTransport({
    host: import.meta.env.EMAIL_HOST,
    port: import.meta.env.EMAIL_PORT,
    secure: false, // true for 465, false for other ports
    auth: {
      user: import.meta.env.EMAIL_USER,
      pass: import.meta.env.EMAIL_PASS,
    },
    tls: {
      rejectUnauthorized: false,
    },
  });

  await transporter.sendMail(msg).then(
    () => {},
    (error) => {
      console.error(error);
      if (error.response) console.error(error.response.body);
    }
  );
}

// Check for Invoice
async function checkInvoice(hash) {
  return axios({
    method: "get",
    url: `${import.meta.env.URL_INVOICE_API}/${hash}`,
    headers: { "X-Api-Key": import.meta.env.INVOICE_KEY },
  })
    .then(function (response) {
      if (response.data.paid) {
        return response.data.details.payment_hash;
      }
      logDim(`Error - Invoice not paid ${hash}`);
      return null;
    })
    .catch((error) => {
      logDim(`Error - fetching Invoice from Lnbits failed\n ${error.message}`);
      return null;
    });
}

async function getKey({ publicKey, serverURL }) {
  console.log(publicKey, serverURL);
  return axios({
    method: "get",
    url: `https://${serverURL}/manager/key`,
    headers: {
      "Content-Type": "application/json",
      Authorization: getAuth(serverURL),
    },
  })
    .then(function (response) {
      let result = response.data.Keys;
      if (result) {
        const keyDBInfo = result.filter((keyEntry) => {
          return publicKey === keyEntry.PublicKey;
        });
        if (keyDBInfo.length != 1) {
          logDim("Error - Key not in Database");
          return null;
        }
        return keyDBInfo[0];
      } else {
        logDim("Server Error - Status 500");
        return null;
      }
    })
    .catch((error) => {
      logDim("getKey()", error.message);
      return null;
    });
}

async function newSubscriptionEnd({ keyID, subExpiry, serverURL, publicKey }) {
  DEBUG &&
    console.log(
      `New Subscription Data:`,
      keyID,
      subExpiry,
      serverURL,
      publicKey,
      parseDate(subExpiry)
    );

  const auth = getAuth(serverURL);

  const request1 = {
    method: "post",
    url: `https://${serverURL}/manager/subscription/edit`,
    headers: {
      "Content-Type": "application/json",
      Authorization: auth,
    },
    data: {
      keyID: `${keyID}`,
      bwLimit: -1, //don't change it
      subExpiry: parseDate(subExpiry),
      bwReset: false,
    },
  };

  console.log(request1);

  const response1 = await axios(request1).catch((error) => {
    logDim("newSubscriptionEnd()- update subscription expiry", error.message);
    return null;
  });

  if (response1.data) {
    // Enable Key if disabled
    const keyInfo = await getKey({ publicKey, serverURL }).catch((error) => {
      logDim("newSubscriptionEnd()-lookupKey", error.message);
      return null;
    });

    DEBUG && logDim(keyInfo.Enabled);

    if (keyInfo.Enabled === "false") {
      const request2 = {
        method: "post",
        url: `https://${serverURL}/manager/key/enable`,
        headers: {
          "Content-Type": "application/json",
          Authorization: auth,
        },
        data: {
          keyID: `${keyID}`,
        },
      };

      const response2 = await axios(request2).catch((error) => {
        logDim(
          `newSubscriptionEnd()- enabling key with ID: ${keyID}`,
          error.message
        );
        return null;
      });

      if (!response2.data) return null;
    }

    return { subExpiry };
  }

  return null;
}

async function getSubscription({ keyID, serverURL }) {
  return axios({
    method: "post",
    url: `https://${serverURL}/manager/subscription`,
    headers: {
      "Content-Type": "application/json",
      Authorization: getAuth(serverURL),
    },
    data: {
      keyID: `${keyID}`,
    },
  })
    .then(function (response) {
      return response.data;
    })
    .catch((error) => {
      console.log(keyID, serverURL);
      logDim("getSubscription()", error.message);
      return null;
    });
}

const getAuth = (serverURL) => {
  const vultrServers = ["br1", "au1"/*, "za1"*/];
  if (serverURL.includes(...vultrServers)) {
    return import.meta.env.AUTH_VULTR;
  }

  return import.meta.env.AUTH;
};
