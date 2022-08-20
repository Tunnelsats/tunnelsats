const express = require('express');
const path = require('path');
const bodyParser = require("body-parser")
const axios = require('axios');
var nodemailer = require('nodemailer');
var dayjs = require('dayjs');
const {logDim} = require('./logger')




DEBUG = true

let invoiceWGKeysMap= []

let localSocket

const app = express();
var payment_hash,payment_request;
require('dotenv').config()

// helper
const getDate = timestamp => (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString()

const createServer = require('http');
const httpServer = createServer.createServer(app);
const io = require("socket.io")(httpServer, {
  cors: {
    // no CORS policy
    orgin: false
  }
});

// Helper
function isEmpty(obj) {
  return Object.keys(obj).length === 0;
}



// Set up the Webserver
app.use(express.static(path.join(__dirname, '../client/build')));
app.use(bodyParser.json());

// Serving the index site
app.get('/', function (req, res) {
  res.sendFile(path.join(__dirname, '../client/build', 'index.html'));
});

// Invoice Webhook
app.post(process.env.WEBHOOK, (req, res) => {

    let keyIDInvoice = ''
   
    const index = invoiceWGKeysMap.findIndex((client) => {
      return client.paymentDetails.payment_hash === req.body.payment_hash
     });

      if(index !== -1) {
       keyIDInvoice = invoiceWGKeysMap[index]

      const {paymentDetails, publicKey,presharedKey,priceDollar,country, id } = keyIDInvoice


      io.to(id).emit('invoicePaid',paymentDetails.payment_hash)

      getWireguardConfig(publicKey,presharedKey,getTimeStamp(priceDollar),getServer(country))
      .then(result => {io.to(id).emit('receiveConfigData',result)
          logDim(`Successfully created wg entry for pubkey ${publicKey}`)
          invoiceWGKeysMap.splice(index,1);
          res.status(200).end()
      })
      .catch(error => {
        console.log(error.message)
        res.status(500).end()

      })
  
    } else {
        logDim(`No Invoice and corresponding connection found in memory`)
        res.status(500).end()

    }

  
});

httpServer.listen(process.env.PORT, '0.0.0.0');
console.log(`${getDate()} httpServer listening on port ${process.env.PORT}`);
// Finish Server Setup




// Socket Connections
io.on('connection', (socket) => {

  console.log(`${getDate()} ${socket.id} io.socket: connected`)

 
  // Checks for a paid Invoice after reconnect
  socket.on('checkInvoice',(clientPaymentHash) => {
    DEBUG && logDim(`checkInvoice() called: ${socket.id}`)
    checkInvoice(clientPaymentHash).then(result => {

      let keyIDInvoice = ''
   
      const index = invoiceWGKeysMap.findIndex((client) => {
        return client.paymentDetails.payment_hash === result
       });
  
        if(index !== -1) {
         keyIDInvoice = invoiceWGKeysMap[index]
  
        const {paymentDetails, publicKey,presharedKey,priceDollar,country, id } = keyIDInvoice
  
        io.to(id).emit('invoicePaid',paymentDetails.payment_hash)
  
        getWireguardConfig(publicKey,presharedKey,getTimeStamp(priceDollar),getServer(country))
        .then(result => {io.to(id).emit('receiveConfigData',result)
            logDim(`Successfully created wg entry for pubkey ${publicKey}`)
            invoiceWGKeysMap.splice(index,1);

        })
        .catch(error => {
          console.log(error.message)
  
        })
    
      } else {
          logDim(`No Invoice and corresponding connection found in memory ${socket.id}`)
          logDim(`no way to recover this state in a secure manner | server crashed potentially`)


      }
  
    }).catch((error)=> logDim(`${error.message}`))
  })

  // Getting the Invoice from lnbits and forwarding it to the frontend
  socket.on('getInvoice',(amount,publicKey,presharedKey,priceDollar,country) =>{
    DEBUG && logDim(`getInvoice() called`)
    


    getInvoice(amount).then(result => {
      
      socket.emit("lnbitsInvoice",result)
      invoiceWGKeysMap.push({paymentDetails: result, publicKey: publicKey, presharedKey: presharedKey, priceDollar: priceDollar, country: country , id : socket.id})
      logDim(`getInvoice()`)
      console.log(invoiceWGKeysMap)

    })

    })
  

  socket.on('sendEmail',(emailAddress,configData,date) => {
    sendEmail(emailAddress,configData,date).then(result => console.log(result))
  })

  

  socket.on('getPrice', () => {
    logDim(`getPrice() id: ${socket.id}`)
    getPrice().then(result => io.to(socket.id).emit('receivePrice', result))
  })

  socket.on('disconnect', () => {
    console.log(`User disconnected with ID: ${socket.id} `)

    let index = 0

    while (index !== -1) {
     index = invoiceWGKeysMap.findIndex((client) => {
      return client.id === socket.id
    });
    if(index !== -1) {
      invoiceWGKeysMap.splice(index,1);
    }
  }

  })    

})

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


  if(selectedValue == 1){
    date = addMonths(date = new Date(),1)
    return date;
  }


  if(selectedValue == 3){
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

   let response1 = await axios(request1).catch(error => { 
      throw new Error(`Error - wgAPI createKey\n ${error.message}`);
    });


    if (!isEmpty(response1.data)){
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
      var response2 = await axios(request2).catch(error => { 
        throw new Error('Error - wgAPI portFwd');
       });

      if(!isEmpty(response2.data)) {
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
       if(response.data.paid)  return response.data.details.payment_hash;
       throw new Error(`Error - Invoice not paid ${hash}`)
  }).catch(error => { 
    throw new Error(`Error - fetching Invoice from Lnbits failed\n ${error.message}`);

   })

};
