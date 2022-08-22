import {Row, Col, Container, Button, Nav, Navbar} from 'react-bootstrap';
import {io} from "socket.io-client";
import {useState} from 'react';
//import KeyInput from './components/KeyInput';
import RuntimeSelector from './components/RuntimeSelector';
import InvoiceModal from './components/InvoiceModal';
import  './wireguard.js';
import {getTimeStamp} from './timefunction.js';
import HeaderInfo from './components/HeaderInfo';
import logo from './media/tunnelsats_headerlogo3.png';
import WorldMap from "./components/WorldMap";
import {Form,InputGroup} from 'react-bootstrap';
import { IoIosRefresh } from 'react-icons/io';



// helper
const getDate = timestamp => (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString();

const DEBUG = true

// WebSocket
let socket =  io.connect('http://localhost:5000');

// Consts
let emailAddress;
let clientPaymentHash;
let isPaid=false;



function App() {


  const [keyPair, displayNewPair] = useState(window.wireguard.generateKeypair());
  const [priceDollar, updatePrice] = useState(8.5);
  const [satsPerDollar, setSatsPerDollar] = useState(Math.round(100000000/23000));
  const [showSpinner, setSpinner] = useState(true);
  const [payment_request, setPaymentrequest] = useState(0);
  const [showPaymentSuccessfull, setPaymentAlert] = useState(false);
  //Modal Invoice
  const [visibleInvoiceModal, setShowInvoiceModal] = useState(false);
  const closeInvoiceModal = () => setShowInvoiceModal(false);
  const showInvoiceModal = () => setShowInvoiceModal(true);
  //Modal Configdata
  const [isConfigModal, showConfigModal] = useState(false);
  const renderConfigModal = () => showConfigModal(true);
  const hideConfigModal = () => showConfigModal(false);
  //LoginModal
  //const [isLoginModal, showLoginModal] = useState(false);
  //const renderLoginModal = () => showLoginModal(true);
  //const hideLoginModal = () => showLoginModal(false);
  
  // World Map
  const [country, updateCountry] = useState('eu');

  /* WorldMap Continent Codes
    AF = Africa
    NA = North America (US+CAD)
    SA = South America (LatAm)
    EU = Europe
    AS = Asia
    OC = Oceania (AUS+NZ)
  */

  // fetch btc price per dollar
  /*
  useEffect(() => {
    // fetch btc price
    const request = setInterval(() => {
      getPrice();
    }, 600000); // 10min
    // clearing interval
    return () => clearInterval(request);
  }, []);
  */

  // // randomize wireguard keys
  // useEffect(() => {
  //   const timer = setInterval(() => {
  //     displayNewPair(window.wireguard.generateKeypair);
  //     DEBUG && console.log(`${getDate()} newKeyPair`);
  //   }, 30000); // 30s
  //   // clearing interval
  //   return () => clearInterval(timer);
  // }, []);

  //Successful payment alert
  const renderAlert = (show) => {
    setPaymentAlert(show);
    setTimeout(() => setPaymentAlert(false), [2000]);
  };

  //Updates the QR-Code
  const updatePaymentrequest = () => {
    socket.on('lnbitsInvoice', invoiceData => {
      DEBUG && console.log(`${getDate()} App.js: got msg lnbitsInvoice`);
      DEBUG && console.log(`${getDate()} Paymenthash: ${invoiceData.payment_hash}, ${invoiceData.payment_request}`)
      setPaymentrequest(invoiceData.payment_request);
      clientPaymentHash = invoiceData.payment_hash;
      setSpinner(false);
    }
  )};


  //Connect to WebSocket Server
  socket.removeAllListeners("connect").on('connect', () => {
    DEBUG && console.log(`${getDate()} App.js: connect with id: ${socket.id}`)
    //Checks for already paid invoice if browser switche tab on mobile
    if((clientPaymentHash !== undefined)){
      checkInvoice();
    }
    // refresh pricePerDollar on start
    getPrice();
  });
  
  // get current btc per dollar
  const getPrice = () => {
    socket.removeAllListeners('getPrice').emit('getPrice');
  }
  socket.off('receivePrice').on('receivePrice', price => {
    DEBUG && console.log(`${getDate()} App.js: server.getPrice(): `+price);
    setSatsPerDollar(Math.trunc(Math.round(price)));
  });

  // check invoice
  const checkInvoice = () => {
      DEBUG && console.log(`${getDate()} App.js: checkInvoice(): ${clientPaymentHash}`);
      socket.emit('checkInvoice',clientPaymentHash);

  };

  //Get the invoice
  const getInvoice = (price,publicKey,presharedKey,priceDollar,country) => {
      DEBUG && console.log(`${getDate()} App.js: getInvoice(price): `+price+`$`);
      socket.emit('getInvoice', price,publicKey,presharedKey,priceDollar,country);
  };


  socket.off('invoicePaid').on('invoicePaid', paymentHash => {
    DEBUG && console.log(`${getDate()} App.js: got msg 'invoicePaid': `+paymentHash+` clientPaymentHash: `+clientPaymentHash);

    if((paymentHash === clientPaymentHash) && !isPaid)
    {
      renderAlert(true);
      isPaid = true;
      setSpinner(true);
    }
  });


  //Get wireguard config from Server
  socket.off('receiveConfigData').on('receiveConfigData',wireguardConfig => {
    DEBUG && console.log(`${getDate()} App.js: got msg receiveConfigData`);
    setSpinner(false);
    setPaymentrequest(buildConfigFile(wireguardConfig).join('\n'));
  });


  

  //Construct the Config File
  const buildConfigFile = (serverResponse) => {
    showInvoiceModal();
    renderConfigModal();
    const configArray = [
    '[Interface]',
    'PrivateKey = '+keyPair.privateKey,
    'Address = '+serverResponse.ipv4Address,
    // 'DNS = '+serverResponse.dns,
    '#VPNPort = '+serverResponse.portFwd,
    '#ValidUntil (UTC time)= '+getTimeStamp(priceDollar).toISOString(),
    ' ',
    '[Peer]',
    'PublicKey = '+serverResponse.publicKey,
    'PresharedKey = '+keyPair.presharedKey,
    'Endpoint = '+serverResponse.dnsName+':'+serverResponse.listenPort,
    'AllowedIPs = '+serverResponse.allowedIPs];
    return configArray;
  };

  //Change Runtime
  const runtimeSelect = (e) =>{
    if(!isNaN(e.target.value)) {
      updatePrice(e.target.value);
    }
  };

//  const countrySelect = (e) => {
//    updateCountry(e.target.value);
//  };

  const download = (filename,text) => {
    const textArray = [text];
    const element = document.createElement("a");
    const file = new Blob(textArray, {
      endings:'native'
    });
    element.href = URL.createObjectURL(file);
    element.download = filename;
    document.body.appendChild(element);
    element.click();
  };

  const sendEmail = (email,config,date) => {
    DEBUG && console.log(`${getDate()} App.js: sendEmail(): `+email+`, validdate: `+date);
    socket.emit('sendEmail',email,config,date);
  };


  return (

    <div>
      <Container>
        <Navbar variant="dark" expanded="true">
          <Container>
            <Navbar.Brand href="#">Tunnel⚡️Sats</Navbar.Brand>
            <Nav className="me-auto">
              <Nav.Link href="https://blckbx.github.io/tunnelsats" target="_blank" rel="noreferrer">Guide</Nav.Link>
              <Nav.Link href="https://blckbx.github.io/tunnelsats/FAQ.html" target="_blank" rel="noreferrer">FAQ</Nav.Link>
            </Nav>
            {/*}
            <Nav>
              <Button onClick={() => renderLoginModal()} variant="outline-info">Login</Button>
              <LoginModal show={isLoginModal} handleClose={hideLoginModal} />
            </Nav>
            */}
          </Container>
        </Navbar>
      </Container>


      <Container className="main-middle">
        <Row>
          <Col>
          <img src={logo} alt=""/>

          <HeaderInfo/>
          
          <WorldMap selected={country} onSelect={updateCountry}/>

          {/*<KeyInput
          publicKey={keyPair.publicKey}
          privateKey={keyPair.privateKey}
          presharedKey={keyPair.presharedKey}
          newPrivateKey={(privateKey) => {keyPair.privateKey = privateKey}}
          newPublicKey={(publicKey) => {keyPair.publicKey = publicKey}}
          newPresharedKey={(presharedKey) => {keyPair.presharedKey = presharedKey}}
          />
          */}
            <Form>
              <Form.Group className="mb-2">
              <InputGroup>
                  <InputGroup.Text>Private Key</InputGroup.Text>
                  <Form.Control
                  disabled
                  key={keyPair.privateKey}
                  defaultValue={keyPair.privateKey}
                  onChange = { (event) => { keyPair.privateKey = (event.target.value)} }
                  />
                  <Button onClick={() => { displayNewPair(window.wireguard.generateKeypair);
                  }} variant="secondary"><IoIosRefresh color="white" size={20} title="renew keys" /></Button>
              </InputGroup>
              <InputGroup>
                  <InputGroup.Text>Public Key</InputGroup.Text>
                  <Form.Control
                  disabled
                  key={keyPair.publicKey}
                  defaultValue={keyPair.publicKey}
                  onChange = { (event) => { keyPair.publicKey = (event.target.value) } }
              />
              </InputGroup>
              <InputGroup>
                  <InputGroup.Text>Preshared Key</InputGroup.Text>
                  <Form.Control
                  disabled
                  key={keyPair.presharedKey}
                  defaultValue={keyPair.presharedKey}
                  onChange = { (event) => { keyPair.presharedKey = (event.target.value) } }
              />
              </InputGroup>
              </Form.Group>

          </Form>

          <RuntimeSelector onClick={runtimeSelect} />

          <InvoiceModal
          show={visibleInvoiceModal}
          showSpinner={showSpinner}
          isConfigModal={isConfigModal}
          value={payment_request}
          download={() => {download("tunnelsatsv2.conf",payment_request)}}
          showNewInvoice={() => {getInvoice(priceDollar*satsPerDollar,keyPair.publicKey,keyPair.presharedKey,country);setSpinner(true)}}
          handleClose={closeInvoiceModal}
          emailAddress = {emailAddress}
          expiryDate = {getTimeStamp(priceDollar)}
          sendEmail = {(data) => sendEmail(data,payment_request,getTimeStamp(priceDollar))}
          showPaymentAlert = {showPaymentSuccessfull}
          />

          <div className='price'>
            <h3>{(Math.trunc(priceDollar*satsPerDollar)).toLocaleString()} <i class="fak fa-satoshisymbol-solidtilt"/></h3>
          </div>

          <div className='main-buttons'>
              <Button onClick={() => { 
                 getInvoice(priceDollar*satsPerDollar,keyPair.publicKey,keyPair.presharedKey,priceDollar,country);
                 showInvoiceModal();
                 hideConfigModal();
                 updatePaymentrequest();
                 setSpinner(true);
                 isPaid=false;
               }} variant="outline-warning">Generate Invoice</Button>
          </div>

          <div className='footer-text'>
            <Row>
              <Col><a href="https://twitter.com/TunnelSats" target="_blank" rel="noreferrer"><span class="icon icon-twitter"></span></a></Col>
              <Col><a href="https://github.com/blckbx/tunnelsats" target="_blank" rel="noreferrer"><span class="icon icon-github"></span></a></Col>
              <Col><a href="https://lnbits.tunnelsats.com/tipjar/1" target="_blank" rel="noreferrer"><span class="icon icon-heart"></span></a></Col>
              <Col><a href="https://t.me/+NJylaUom-rxjYjU6" target="_blank" rel="noreferrer"><span class="icon icon-telegram"></span></a></Col>
            </Row>
          </div>

          </Col>
        </Row>
      </Container>
    </div>
  );
};

export default App;
