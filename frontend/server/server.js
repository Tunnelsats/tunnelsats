const express = require('express');
const path = require('path');
const bodyParser = require("body-parser")
const axios = require('axios');
var nodemailer = require('nodemailer');
var dayjs = require('dayjs');
const {logDim} = require('./logger')


DEBUG = false

const app = express();
var payment_hash,payment_request;
require('dotenv').config()

// helper
const getDate = timestamp => (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString()

const createServer = require('http');
const httpServer = createServer.createServer(app);
const io = require("socket.io")(httpServer);

// Set up the Webserver
app.use(express.static(path.join(__dirname, '../client/build')));
app.use(bodyParser.json());

// Serving the index site
app.get('/', function (req, res) {
  res.sendFile(path.join(__dirname, '../client/build', 'index.html'));
});

// Invoice Webhook
app.post(process.env.WEBHOOK, (req, res) => {
    io.sockets.emit('invoicePaid',req.body.payment_hash)
    res.status(200).end()
});

httpServer.listen(process.env.PORT, '0.0.0.0');
console.log(`${getDate()} httpServer listening on port ${process.env.PORT}`);
// Finish Server Setup

// Socket Connections
io.on('connection', (socket) => {

  console.log(`${getDate()} io.socket: connected`)

  // Checks for a paid Invoice after reconnect
  socket.on('checkInvoice',(clientPaymentHash) => {
    DEBUG && logDim("checkInvoice() called")
    checkInvoice(clientPaymentHash).then(result => io.sockets.emit('invoicePaid',result))
  })

  // Getting the Invoice from lnbits and forwarding it to the frontend
  socket.on('getInvoice',(amount) =>{
    DEBUG && logDim(`getInvoice() called`)
    getInvoice(amount).then(result => socket.emit("lnbitsInvoice",result))
  })

  socket.on('sendEmail',(emailAddress,configData,date) => {
    sendEmail(emailAddress,configData,date).then(result => console.log(result))
  })

  socket.on('getWireguardConfig',(publicKey,presharedKey,priceDollar,country) => {
    getWireguardConfig(publicKey,presharedKey,getTimeStamp(priceDollar),getServer(country))
    .then(result => socket.emit('receiveConfigData',result))
  })

  socket.on('getPrice', () => {
    getPrice().then(result => socket.emit('receivePrice', result))
  })

});

//Transforms country into server
var getServer = (country) => {
  var server;
  if (country == "eu"){
    server = process.env.IP_EU;
  }
  if (country == "na"){
    server = process.env.IP_USA;
  }
  if (country == "sa"){
    server = process.env.IP_LATAM;
  }
  if (country == "af"){
    server = process.env.IP_AFRICA;
  }
  if (country == "as"){
    server = process.env.IP_ASIA;
  }
  if (country == "oc"){
    server = process.env.IP_OCEANIA;
  }  
  return server;
}


// Transforms duration into timestamp
var getTimeStamp = (selectedValue) =>{
  
  var date;
  if(selectedValue == 0.01){
    date = addMonths(date = new Date(),1)
    return date;
  }

  if(selectedValue == 0.02){
    date = addMonths(date = new Date(),3)
    return date;
  }

  if(selectedValue == 0.03){
    date = addMonths(date = new Date(),6)
    return date;
  }

  if(selectedValue == 0.04){
    date = addMonths(date = new Date(),12)
    return date;
  }

  function addMonths(date = new Date(), months) {
    var d = date.getDate();
    date.setMonth(date.getMonth() + +months);
    if (date.getDate() != d) {
      date.setDate(0);
    }
    return date;
  }
}


// Get Invoice Function
async function getInvoice(amount) {
  var satoshis = await getPrice()
                        .then((result) => { return result })
                        .catch((error) => { return error });
  return axios({
  method: "post",
  url: process.env.URL_INVOICE_API,
  headers: { "X-Api-Key": process.env.INVOICE_KEY},
  data: {
    "out": false,
    "amount": satoshis*amount,
    "memo": getTimeStamp(amount),
    "webhook" : process.env.URL_WEBHOOK
  }
    }).then(function (response){
      if(response) {
        payment_request = response.data.payment_request;
        payment_hash = response.data.payment_hash;
        return {payment_hash,payment_request}
      }
    }).catch(error => {
      return error
    });
};

// Get Bitcoin Price in Satoshi per Dollar
async function getPrice() {
  return axios({
    method: "get",
    url: process.env.URL_PRICE_API
  }).then(function (response){
    if(response) {
      const priceBTC = (response.data.USD.buy);
      var priceOneDollar = (100000000 / priceBTC);
      return priceOneDollar;
    }
  }).catch(error => {
    return error;
  });
};


// Get Wireguard Config
async function getWireguardConfig(publicKey,presharedKey,timestamp,server) {

   const request1 = {
    method: 'post',
    url: server+'key',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': process.env.AUTH
    },
    data: {
     "publicKey": publicKey,
     "presharedKey": presharedKey,
     "bwLimit": 100000, // 100GB
     "subExpiry": parseDate(timestamp),
     "ipIndex": 0
    }
   };

   var response1 = await axios(request1).catch(error => { return error });

    if(!response1) {
      response1 = await axios(request1).catch(error => { return error });
    } else {
      const request2 = {
        method: 'post',
        url: server+'portFwd',
        headers: {
        'Content-Type': 'application/json',
        'Authorization': process.env.AUTH
        },
        data: {
        "keyID": response1.data.keyID
        }
      }

      var response2 = await axios(request2).catch(error => { return error });
      
      if(!response2) {
        response2 = await axios(request2).catch(error => { return error });
      } else {
        response1.data['portFwd'] = response2.data.portFwd;
        response1.data['dnsName'] = (server.replace(/^https?:\/\//, '')).replace(/\/manager\/$/, '');
        return response1.data;
      }
    }
};


// Parse Date object to string format: YYYY-MMM-DD hh:mm:ss A
const parseDate = (date) => { return dayjs(date).format("YYYY-MMM-DD hh:mm:ss A") };


// Send Wireguard config file via email
async function sendEmail(emailAddress,configData,date) {

    const msg = {
      to: emailAddress,
      from: 'payment@tunnelsats.com',
      subject: 'Your Tunnel Sats VPN config file for Wireguard. Valid until: '+date.toString(),
      text: "Thank you for using Tunnel Sats!\n\nFind your personal config file attached. Don't loose it!\n\nYour subscription is valid until: "+date.toString(),
      attachments: [
        {
          content: configData,
          filename: 'lndHybridMode.conf',
          contentType : "text/plain",
          endings:'native',
          disposition: 'attachment'
        }
      ],
    };

   let transporter = nodemailer.createTransport({
        host: process.env.EMAIL_HOST,
        port: process.env.EMAIL_PORT,
        secure: false, // true for 465, false for other ports
        auth: {
          user: process.env.EMAIL_USER,
          pass: process.env.EMAIL_PASS
        },
        tls: {
            rejectUnauthorized: false
        }
      });

   await transporter.sendMail(msg)
               .then(() => {}, error => {
                 console.error(error);
               if (error.response) console.error(error.response.body);
              });
};

// Check for Invoice
async function checkInvoice(hash) {
  return axios({
       method: "get",
       url: process.env.URL_INVOICE_API +"/"+hash,
       headers: { "X-Api-Key": process.env.INVOICE_KEY }
  }).then(function (response){
       if(response.data.paid) return response.data.details.payment_hash;
  }).catch(error => { return error })
};
