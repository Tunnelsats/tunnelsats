const express = require("express");
const path = require("path");
const bodyParser = require("body-parser");
const axios = require("axios");
const nodemailer = require("nodemailer");
const dayjs = require("dayjs");
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

// 15 minutes after the invoice is in memory it is purged after any user disconnects
const TIMERINVOICEDATA = 15;

const app = express();

// helper
const getDate = (timestamp) =>
  (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString();
function isEmpty(obj) {
  return Object.keys(obj).length === 0;
}

// Telegram Settings
const TELEGRAM_CHATID = process.env.TELEGRAM_CHATID || "";
const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN || "";
const TELEGRAM_PREFIX = process.env.TELEGRAM_PREFIX || "";

// Tor Proxy for Telegram Bot
const TELEGRAM_PROXY_HOST = process.env.TELEGRAM_PROXY_HOST || "";
const TELEGRAM_PROXY_PORT = process.env.TELEGRAM_PROXY_PORT || "";

// Env Variables to have the same code base main and dev
const REACT_APP_ONE_MONTH = process.env.REACT_APP_ONE_MONTH || 0.001;
const REACT_APP_THREE_MONTHS = process.env.REACT_APP_THREE_MONTHS || 0.002;
const REACT_APP_SIX_MONTHS = process.env.REACT_APP_SIX_MONTHS || 0.003;
const REACT_APP_ONE_YEAR = process.env.REACT_APP_ONE_YEAR || 0.004;

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

  message = `[Tunnelsats-${TELEGRAM_PREFIX}.js] ` + message;

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
app.post(process.env.WEBHOOK, (req, res) => {
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

    // Needed for now to notify the client to stop the spinner
    io.to(id).emit("invoicePaid", paymentDetails.payment_hash);

    // Looks through the invoice map saved into ram and sends the config ONLY to the relevant client
    getWireguardConfig(
      publicKey,
      presharedKey,
      getTimeStamp(priceDollar),
      getServer(country)
    )
      .then((result) => {
        io.to(id).emit("receiveConfigData", result);
        logDim(`Successfully created wg entry for pubkey ${publicKey}`);

        invoiceWGKeysMap[index].isPaid = true;
        invoiceWGKeysMap[index].resultAddingKey = result;

        const serverDNS = getServer(country)
          .replace(/^https?:\/\//, "")
          .replace(/\/manager\/$/, "");
        sayWithTelegram({
          message: `🟢 New Subscription: 🍾\n Price: ${priceDollar}\$\n ServerLocation: ${serverDNS}\n Sats: ${Math.round(
            amountSats
          )}💰`,
        })
          .then((result) => {
            DEBUG && logDim(`getConfig(): ${result}`);
          })
          .catch((error) => logDim(error.message));

        res.status(200).end();
      })
      .catch((error) => {
        DEBUG && logDim(`getConfig(): ${error.message}`);
        sayWithTelegram({
          message: `🔴 Creating New Subscription failed with ${error.message}`,
        });
        res.status(500).end();
      });
  } else {
    logDim(`No Invoice and corresponding connection found in memory`);
    logDim(`Probably Server crashed and lost invoice memory`);

    res.status(500).end();
  }
});

// Webhook for updating the Subcription

// Invoice Webhook
app.post(process.env.WEBHOOK_UPDATE_SUB, (req, res) => {
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

    // Needed for now to notify the client to stop the spinner
    io.to(id).emit(
      "invoicePaidUpdateSubscription",
      paymentDetails.payment_hash
    );

    getSubsciption({
      keyID,
      serverURL,
    })
      .then((result) => {
        newSubscriptionEnd({
          keyID,
          subExpiry: getTimeStamp(priceDollar, result.subscriptionEnd),
          serverURL,
          publicKey,
        })
          .then((result) => {
            io.to(id).emit("receiveUpdateSubscription", result);
            logDim(
              `Successfully updated new SubscriptionEnd for  ${publicKey}`
            );
            sayWithTelegram({
              message: `🟢 Renewed Subscription: 🍾\n Price: ${priceDollar}\$\n PubKey: ${publicKey}\n Sats: ${Math.round(
                amountSats
              )}💰`,
            });
            invoiceWGKeysMap.splice(index, 1);
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
  }
});

httpServer.listen(process.env.PORT, "0.0.0.0");
console.log(`${getDate()} httpServer listening on port ${process.env.PORT}`);

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
          const { paymentDetails, publicKey, isPaid, resultAddingKey } =
            invoiceWGKeysMap[index];

          if (isPaid) {
            io.to(socket.id).emit("invoicePaid", paymentDetails.payment_hash);

            io.to(socket.id).emit("receiveConfigData", resultAddingKey);
            logDim(
              `Resend wg credentials to already paid invoice entry for pubkey ${publicKey}`
            );
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
  socket.on(
    "getInvoice",
    (amount, publicKey, presharedKey, priceDollar, country) => {
      DEBUG && logDim(`getInvoice() called id: ${socket.id}`);

      if (invoiceWGKeysMap.length <= MAXINVOICES) {
        getInvoice(amount, priceDollar, process.env.URL_WEBHOOK)
          .then((result) => {
            socket.emit("lnbitsInvoice", result);

            // Safes the client request related to the socket id including the payment_hash to later send the config data only to the right client
            invoiceWGKeysMap.push({
              paymentDetails: result,
              publicKey: publicKey,
              presharedKey: presharedKey,
              priceDollar: priceDollar,
              country: country,
              id: socket.id,
              amountSats: amount,
              timestamp: Date.now(),
              isPaid: false,
            });
            DEBUG && console.log(invoiceWGKeysMap);
          })
          .catch((error) => logDim(error.message));
      } else {
        logDim(
          `restrict overall invoices to ${MAXINVOICES} to prevent mem overflow `
        );
      }
    }
  );

  // New Listening events for UpdateSubscription Request

  socket.on("checkKeyDB", ({ publicKey /*, serverURL */ }) => {
    console.log(publicKey /*, serverURL*/);

    let keyID;
    const servers = [
      "de1.tunnelsats.com",
      "us1.tunnelsats.com",
      "sg1.tunnelsats.com",
      "ca1.tunnelsats.com", //testserver
    ];

    servers.forEach((server) => {
      console.log(`server: ${server}`);
      getKey({ publicKey, serverURL: server })
        .then((result) => {
          keyID = result.KeyID;
          getSubsciption({
            keyID: result.KeyID,
            serverURL: server,
          })
            .then((result) => {
              console.log(result);
              let unixTimestamp = Date.parse(result.subscriptionEnd);
              let date = new Date(unixTimestamp);
              logDim("SubscriptionEnd: ", date.toISOString());

              socket.emit("receiveKeyLookup", {
                keyID: keyID,
                subscriptionEnd: date,
              });
            })
            .catch((error) => {
              logDim(`getSubscription: ${error.message}`);
              //socket.emit("receiveKeyLookup", "Error - No Subscription Found");
            });
        })
        .catch((error) => {
          logDim(`getKey: ${error.message}`);
          //socket.emit("receiveKeyLookup", "key not found");
        });
    });
  });

  socket.on(
    "getInvoiceUpdateSub",
    ({ amount, publicKey, keyID, country, priceDollar }) => {
      DEBUG && logDim(`getInvoiceUpdateSub() called id: ${socket.id}`);

      if (invoiceWGKeysMap.length <= MAXINVOICES) {
        getInvoice(amount, priceDollar, process.env.URL_WEBHOOK_UPDATE_SUB)
          .then((result) => {
            socket.emit("lnbitsInvoiceSubscription", result);

            const serverURL = getServer(country)
              .replace(/^https?:\/\//, "")
              .replace(/\/manager\/$/, "");

            // Safes the client request related to the socket id including the payment_hash to later send the config data only to the right client
            invoiceWGKeysMap.push({
              paymentDetails: result,
              publicKey: publicKey,
              keyID: keyID,
              priceDollar: priceDollar,
              serverURL: serverURL,
              id: socket.id,
              amountSats: amount,
              tag: "Update Subscription",
            });
            DEBUG && console.log(invoiceWGKeysMap);
          })
          .catch((error) => logDim(error.message));
      } else {
        logDim(
          `restrict overall invoices to ${MAXINVOICES} to prevent mem overflow`
        );
      }
    }
  );

  socket.on("getServer", (country) => {
    logDim(`getServer() called id: ${socket.id}`);
    server = getServer(country);
    socket.emit(
      "receiveServer",
      server.replace(/^https?:\/\//, "").replace(/\/manager\/$/, "")
    );
  });

  socket.on("sendEmail", (emailAddress, configData, date) => {
    sendEmail(emailAddress, configData, date).then((result) =>
      console.log(result)
    );
  });

  socket.on("getPrice", () => {
    logDim(`getPrice() id: ${socket.id}`);
    getPrice().then((result) => io.to(socket.id).emit("receivePrice", result));
  });

  socket.on("disconnect", () => {
    console.log(`User disconnected with ID: ${socket.id} `);

    let index = 0;

    const currentTime = Date.now();

    // Delete all user related information
    while (index !== -1) {
      index = invoiceWGKeysMap.findIndex((client) => {
        // console.log(currentTime - client.timestamp);
        // After 15 Minutes Invoice Related Date is purged from the memory
        return currentTime - client.timestamp > 1000 * 60 * TIMERINVOICEDATA;
      });
      if (index !== -1) {
        invoiceWGKeysMap.splice(index, 1);
      }
    }
  });
});

//Transforms country into server
const getServer = (country) => {
  let server;

  if (country == "eu") {
    server = process.env.IP_EU;
  }
  if (country == "na") {
    server = process.env.IP_USA;
  }
  if (country == "sa") {
    server = process.env.IP_LATAM;
  }
  if (country == "af") {
    server = process.env.IP_AFRICA;
  }
  if (country == "as") {
    server = process.env.IP_ASIA;
  }
  if (country == "oc") {
    server = process.env.IP_OCEANIA;
  }
  return server;
};

// Transforms duration into timestamp
const getTimeStamp = (selectedValue, offset) => {
  let date = new Date();
  if (offset && Date.now() < Date.parse(offset)) {
    let unixtime = Date.parse(offset);
    date = new Date(unixtime);
  }

  if (selectedValue == REACT_APP_ONE_MONTH) {
    date = addMonths(date, 1);
    return date;
  }

  if (selectedValue == REACT_APP_THREE_MONTHS) {
    date = addMonths(date, 3);
    return date;
  }

  if (selectedValue == REACT_APP_SIX_MONTHS) {
    date = addMonths(date, 6);
    return date;
  }

  if (selectedValue == REACT_APP_ONE_YEAR) {
    date = addMonths(date, 12);
    return date;
  }

  function addMonths(date = new Date(), months) {
    const d = date.getDate();
    date.setMonth(date.getMonth() + +months);
    if (date.getDate() != d) {
      date.setDate(0);
    }
    return date;
  }
};

// Parse Date object to string format: YYYY-MMM-DD hh:mm:ss A
const parseDate = (date) => {
  return dayjs(date).format("YYYY-MMM-DD hh:mm:ss A");
};

// API Calls using Axios

// Get Invoice Function
async function getInvoice(amount, priceDollar, webhook) {
  // let satoshis = await getPrice()
  //                       .then((result) => { return result })
  //                       .catch(error => { return error });
  return axios({
    method: "post",
    url: process.env.URL_INVOICE_API,
    headers: { "X-Api-Key": process.env.INVOICE_KEY },
    data: {
      out: false,
      amount: Math.round(amount),
      memo: getTimeStamp(priceDollar),
      webhook,
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
    url: process.env.URL_PRICE_API,
  })
    .then(function (response) {
      if (!isEmpty(response.data)) {
        return 100_000_000 / response.data.USD.buy;
      }
    })
    .catch((error) => {
      return error;
    });
}

// Get Wireguard Config
async function getWireguardConfig(publicKey, presharedKey, timestamp, server) {
  const request1 = {
    method: "post",
    url: server + "key",
    headers: {
      "Content-Type": "application/json",
      Authorization: process.env.AUTH,
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
    throw new Error(`Error - wgAPI createKey\n ${error.message}`);
  });

  if (!isEmpty(response1.data)) {
    const request2 = {
      method: "post",
      url: server + "portFwd",
      headers: {
        "Content-Type": "application/json",
        Authorization: process.env.AUTH,
      },
      data: {
        keyID: response1.data.keyID,
      },
    };

    const response2 = await axios(request2).catch((error) => {
      throw new Error(`Error - wgAPI portFwd\n ${error.message}`);
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
    subject: `Your Tunnel Sats VPN config file for Wireguard. Valid until: ${date.toString()}`,
    text: `Thank you for using Tunnel Sats!\n\nFind your personal config file attached. Don't lose it!\n\nYour subscription is valid until: ${date.toString()}`,
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
    host: process.env.EMAIL_HOST,
    port: process.env.EMAIL_PORT,
    secure: false, // true for 465, false for other ports
    auth: {
      user: process.env.EMAIL_USER,
      pass: process.env.EMAIL_PASS,
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
    url: `${process.env.URL_INVOICE_API}/${hash}`,
    headers: { "X-Api-Key": process.env.INVOICE_KEY },
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
      Authorization: process.env.AUTH,
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
  console.log(
    `new data: ${parseDate(subExpiry)}`,
    keyID,
    subExpiry,
    serverURL,
    publicKey
  );
  const request1 = {
    method: "post",
    url: `https://${serverURL}/manager/subscription/edit`,
    headers: {
      "Content-Type": "application/json",
      Authorization: process.env.AUTH,
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
    const isEnabled = await getKey({ publicKey, serverURL }).catch((error) => {
      logDim("newSubscriptionEnd()-lookupKey", error.message);
      return null;
    });

    console.log(`enabled: ${isEnabled}`);

    if (!isEnabled) {
      const request2 = {
        method: "post",
        url: `https://${serverURL}/manager/enable`,
        headers: {
          "Content-Type": "application/json",
          Authorization: process.env.AUTH,
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

async function getSubsciption({ keyID, serverURL }) {
  return axios({
    method: "post",
    url: `https://${serverURL}/manager/subscription`,
    headers: {
      "Content-Type": "application/json",
      Authorization: process.env.AUTH,
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
