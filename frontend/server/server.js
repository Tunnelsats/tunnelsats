const express = require('express');
const path = require('path');
const bodyParser = require("body-parser")
const axios = require('axios');
var nodemailer = require('nodemailer');
var dayjs = require('dayjs');

const app = express();
var payment_hash,payment_request;
require('dotenv').config()

const createServer = require('http');
const httpServer = createServer.createServer(app);
const io = require("socket.io")(httpServer, {
  cors: {
    origin: ["https://tunnelsats.com", "https://www.tunnelsats.com", "http://localhost", "http://127.0.0.1"],
    credentials: true
  }
});

// Set up the Webserver
app.use(express.static(path.join(__dirname, '../client/build')));
app.use(bodyParser.json())

// Serving the index site
app.get('/', function (req, res) {
  res.sendFile(path.join(__dirname, '../client/build', 'index.html'));
});

// Invoice Webhook
app.post(process.env.WEBHOOK, (req, res) => {
    io.sockets.emit('invoicePaid',req.body.payment_hash)
    res.status(200).end()
})

httpServer.listen(process.env.PORT);
// Finish Server Setup

// Socket Connections
io.on('connection', (socket) => {

  // Checks for a paid Invoice after reconnect
  socket.on('checkInvoice',(clientPaymentHash) => {
    checkInvoice(clientPaymentHash).then(result => io.sockets.emit('invoicePaid',result))
  })

  // Getting the Invoice from lnbits and forwarding it to the frontend
  socket.on('getInvoice',(amount) =>{
    getInvoice(amount).then(result => socket.emit("lnbitsInvoice",result))
  })

  socket.on('sendEmail',(emailAddress,configData,date) => {
    sendEmail(emailAddress,configData,date).then(result => console.log(result))
  })

  socket.on('getWireguardConfig',(publicKey,presharedKey,priceDollar,country) => {
    getWireguardConfig(publicKey,presharedKey,getTimeStamp(priceDollar),getServer(country))
    .then(result => socket.emit('recieveConfigData',result))
  })

  socket.on('getPrice', () => {
    getPrice().then(result => socket.emit('recievePrice', result))
  })

});

//Transforms country into server
var getServer = (country) => {
  var server;
  if (country == "eu"){
    server = process.env.IP_EU
  }
  if (country == "na"){
    server = process.env.IP_USA
  }
  if (country == "sa"){
    server = process.env.IP_LATAM
  }
  if (country == "af"){
    server = process.env.IP_AFRICA
  }
  if (country == "as"){
    server = process.env.IP_ASIA
  }
  if (country == "oc"){
    server = process.env.IP_OCEANIA
  }  
  return server;
}


// Transforms duration into timestamp
var getTimeStamp = (selectedValue) =>{
  
  var date;
  if(selectedValue == 0.1){
    date = addMonths(date = new Date(),1)
    return date;
  }

  if(selectedValue == 8.5){
    date = addMonths(date = new Date(),3)
    return date;
  }

  if(selectedValue == 16){
    date = addMonths(date = new Date(),6)
    return date;
  }

  if(selectedValue == 28.5){
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
                        .catch(error => { return error });
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
      payment_request = response.data.payment_request;
      payment_hash = response.data.payment_hash;
      return {payment_hash,payment_request}
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
     const priceBTC = (response.data.USD.buy);
     var priceOneDollar = (100000000 / priceBTC);
     return priceOneDollar;
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
      };

     var response2 = await axios(request2).catch(error => { return error });
      
     if(!response2) {
      response2 = await axios(request2).catch(error => { return error });
     } else {
      response1.data['portFwd'] = response2.data.portFwd;
      return response1.data;
     }
    }
};


// Parse Date object to string format: YYYY-MMM-DD hh:mm:ss A
const parseDate = (date) => {
  var durationEnd = dayjs(date).format("YYYY-MMM-DD hh:mm:ss A")
  return durationEnd
};

// translate IP to DNS
async function getDNS(ipAddress) {
  var dns;
  if (ipAddress == "process.env.IP_EU") dns = process.env.DNS_EU;
  if (ipAddress == "process.env.IP_US") dns = process.env.DNS_US;
//   if (ipAddress == "") dns = process.env.DNS_AFRICA;  
//   if (ipAddress == "") dns = process.env.DNS_LATAM;
//   if (ipAddress == "") dns = process.env.DNS_ASIA;
//   if (ipAddress == "") dns = process.env.DNS_OCEANIA;
  return dns;
};


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

   let info = await transporter
               .sendMail(msg)
               .then(() => {}, error => {
                 console.error(error);
               if (error.response) {
                 console.error(error.response.body)
               }
              });

  // console.log("Message sent: %s", info.messageId);

};

// Check for Invoice
async function checkInvoice(hash) {
  return axios({
       method: "get",
       url: process.env.URL_INVOICE_API +"/"+hash,
       headers: { "X-Api-Key": process.env.INVOICE_KEY }
  }).then(function (response){
       if(response.data.paid)  {
          return response.data.details.payment_hash;
       }
  }).catch(error => { 
    return error 
  })
};
