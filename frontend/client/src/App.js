import {
  Row,
  Col,
  Container,
  Button,
  Nav,
  Navbar,
  Spinner,
  Collapse,
  Form,
  InputGroup,
  //Toast,
} from "react-bootstrap";
import io from "socket.io-client";
import { useState } from "react";
import RuntimeSelector from "./components/RuntimeSelector";
import InvoiceModal from "./components/InvoiceModal";
import RenewInvoiceModal from "./components/RenewInvoiceModal";
import Popup from "./components/Popup";
import { getTimeStamp } from "./timefunction.js";
import HeaderInfo from "./components/HeaderInfo";
import logo from "./media/tunnelsats_headerlogo5.png";
//import logo from "./media/tunnelsats_headerlogo5_BF.png";
import WorldMap from "./components/WorldMap";
import { IoIosRefresh, IoIosInformationCircleOutline } from "react-icons/io";
import "./wireguard.js";

// helper
const getDate = (timestamp) =>
  (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString();
const base64regex =
  /^([0-9a-zA-Z+/]{4})*(([0-9a-zA-Z+/]{2}==)|([0-9a-zA-Z+/]{3}=))?$/;

// Env Variables to have the same code base main and dev
const REACT_APP_THREE_MONTHS = process.env.REACT_APP_THREE_MONTHS || 8.5;
const REACT_APP_LNBITS_URL = process.env.REACT_APP_LNBITS_URL || "";
const REACT_APP_SOCKETIO = process.env.REACT_APP_SOCKETIO || "/";

const REACT_APP_REF = process.env.REACT_APP_REF || "";
const REACT_APP_DISCOUNT = parseFloat(process.env.REACT_APP_DISCOUNT);

const DEBUG = false;

// WebSocket
var socket = io.connect(REACT_APP_SOCKETIO);

// Consts
var emailAddress;
var clientPaymentHash;
var isPaid = false;
var keyID;

function App() {
  const [keyPair, displayNewPair] = useState(
    window.wireguard.generateKeypair()
  );
  const [priceDollar, updatePrice] = useState(REACT_APP_THREE_MONTHS);
  const [satsPerDollar, setSatsPerDollar] = useState(
    Math.round(100000000 / 20000)
  );
  const [showSpinner, setSpinner] = useState(true);
  const [showSpinnerQuery, setSpinnerQuery] = useState(false);
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
  const [country, updateCountry] = useState("eu2");

  /* WorldMap Continent Codes
    AF = Africa
    NA = North America (US+CAD)
    SA = South America (LatAm)
    EU = Europe
    AS = Asia
    OC = Oceania (AUS+NZ)
  */

  // switch first <-> renew subscription
  const [isRenewSub, setRenewSub] = useState(false);
  const showRenew = () => setRenewSub(true);
  const hideRenew = () => setRenewSub(false);

  const [server, setServer] = useState("");
  const [pubkey, setPubkey] = useState("");
  const [valid, setValid] = useState(false);
  const [timeValid, setTimeValid] = useState(false);
  const [timeValidOld, setTimeValidOld] = useState(false);
  const [timeSubscription, setTime] = useState("");
  const [newTimeSubscription, setNewTime] = useState("");
  // Popup - Key Query
  const [isPopupModal, showPopupModal] = useState(false);
  const renderPopupModal = () => showPopupModal(true);
  const hidePopupModal = () => showPopupModal(false);
  const [popupMessage, setPopupMessage] = useState("");

  // special discounts
  const [discount, setDiscount] = useState(1.0);

  // node stats from mempool.space
  const [nodeStats, setNodeStats] = useState([0, 0, 0, 0]);

  // github last commit hash
  const [commitHash, setCommitHash] = useState("");

  // toast
  //const [showA, setShowA] = useState(true);
  //const toggleShowA = () => setShowA(!showA);

  //Successful payment alert
  const renderAlert = (show) => {
    setPaymentAlert(show);
    setTimeout(() => setPaymentAlert(false), [2000]);
  };

  //Updates the QR-Code
  const updatePaymentrequest = () => {
    socket.on("lnbitsInvoice", (invoiceData) => {
      DEBUG && console.log(`${getDate()} App.js: got msg lnbitsInvoice`);
      setPaymentrequest(invoiceData.payment_request);
      clientPaymentHash = invoiceData.payment_hash;
      DEBUG && console.log(clientPaymentHash);
      setSpinner(false);
    });
  };

  //Connect to WebSocket Server
  socket.removeAllListeners("connect").on("connect", () => {
    DEBUG && console.log(`${getDate()} App.js: connect with id: ${socket.id}`);
    //Checks for already paid invoice if browser switche tab on mobile
    if (clientPaymentHash !== undefined) {
      checkInvoice();
    }
    // refresh pricePerDollar on start
    getPrice();

    // check for discounts
    getDiscount();

    // get node stats
    getNodeStats();

    // get latest commit hash
    getCommitHash();
  });

  // get node stats from mempool.space
  const getNodeStats = () => {
    socket.removeAllListeners("getNodeStats").emit("getNodeStats");
    DEBUG &&
      console.log(`${getDate()} App.js: server.getNodeStats() ${socket.id}`);
  };

  socket.off("receiveNodeStats").on("receiveNodeStats", (result) => {
    DEBUG &&
      console.log(
        `${getDate()} App.js: server.receiveNodeStats() ${[
          result.node_count - result.unannounced_nodes,
          result.clearnet_nodes,
          result.clearnet_tor_nodes,
          result.tor_nodes,
        ]}`
      );
    setNodeStats([
      result.node_count - result.unannounced_nodes,
      result.clearnet_nodes,
      result.clearnet_tor_nodes,
      result.tor_nodes,
    ]);
  });

  const getDiscount = () => {
    // parse URL for search params
    const queryParams = new URLSearchParams(window.location.search);
    const param = queryParams.get("ref");
    // set discount per ref
    if (param == REACT_APP_REF) {
      setDiscount(REACT_APP_DISCOUNT);
    }
  };

  /*
  socket.removeAllListeners("receiveServer").on("receiveServer", (server) => {
    DEBUG && console.log(`${getDate()} App.js: received server: `, server);
    setServer(server);
  });
  */

  // get current btc per dollar
  const getPrice = () => {
    socket.removeAllListeners("getPrice").emit("getPrice");
    setSpinner(true);
  };

  socket.off("receivePrice").on("receivePrice", (price) => {
    DEBUG && console.log(`${getDate()} App.js: server.getPrice(): ${price}`);
    setSatsPerDollar(Math.trunc(Math.round(price)));
    setSpinner(false);
  });

  // get latest git commit hash
  const getCommitHash = () => {
    socket.removeAllListeners("getCommitHash").emit("getCommitHash");
  };

  socket.off("receiveCommitHash").on("receiveCommitHash", (hash) => {
    DEBUG &&
      console.log(`${getDate()} App.js: server.getCommitHash(): ${hash}`);
    setCommitHash(hash);
  });

  // check invoice
  const checkInvoice = () => {
    DEBUG &&
      console.log(`${getDate()} App.js: checkInvoice(): ${clientPaymentHash}`);
    socket.emit("checkInvoice", clientPaymentHash);
  };

  //Get the invoice
  const getInvoice = (price, publicKey, presharedKey, priceDollar, country) => {
    DEBUG && console.log(`${getDate()} App.js: getInvoice(price): ${price}$`);
    socket.emit(
      "getInvoice",
      price,
      publicKey,
      presharedKey,
      priceDollar,
      country
    );
  };

  socket.off("invoicePaid").on("invoicePaid", (paymentHash) => {
    DEBUG &&
      console.log(
        `${getDate()} App.js: got msg 'invoicePaid': ${paymentHash}, clientPaymentHash: ${clientPaymentHash}`
      );

    if (paymentHash === clientPaymentHash && !isPaid) {
      renderAlert(true);
      isPaid = true;
      setSpinner(true);
    }
  });

  //Get wireguard config from Server
  socket.off("receiveConfigData").on("receiveConfigData", (wireguardConfig) => {
    DEBUG && console.log(`${getDate()} App.js: got msg receiveConfigData`);
    setSpinner(false);
    setPaymentrequest(buildConfigFile(wireguardConfig).join("\n"));
  });

  //Construct the Config File
  const buildConfigFile = (serverResponse) => {
    showInvoiceModal();
    renderConfigModal();
    const configArray = [
      "[Interface]",
      "PrivateKey = " + keyPair.privateKey,
      "Address = " + serverResponse.ipv4Address,
      " ",
      "#VPNPort = " + serverResponse.portFwd,
      "#ValidUntil (UTC time) = " + getTimeStamp(priceDollar).toISOString(),
      "#myPubKey = " + keyPair.publicKey,
      " ",
      "[Peer]",
      "PublicKey = " + serverResponse.publicKey,
      "PresharedKey = " + keyPair.presharedKey,
      "Endpoint = " + serverResponse.dnsName + ":" + serverResponse.listenPort,
      "AllowedIPs = " + serverResponse.allowedIPs,
      "PersistentKeepalive = 25",
    ];
    return configArray;
  };

  //Change Runtime
  const runtimeSelect = (e) => {
    if (!isNaN(e.target.value)) {
      updatePrice(e.target.value);
      if (timeSubscription) {
        setNewTime(
          getTimeStamp(e.target.value, timeSubscription).toISOString()
        );
      }
    }
  };

  const download = (filename, text) => {
    const textArray = [text];
    const element = document.createElement("a");
    const file = new Blob(textArray, {
      endings: "native",
    });
    element.href = URL.createObjectURL(file);
    element.download = filename;
    document.body.appendChild(element);
    element.click();
  };

  const sendEmail = (email, config, date) => {
    DEBUG &&
      console.log(
        `${getDate()} App.js: sendEmail(): ${email}, validdate: ${date}`
      );
    socket.emit("sendEmail", email, config, date);
  };

  // renew subscription methods

  /*
  useEffect(() => {
    setNewTime("");
    setTime("");
    setTimeValid(false);
    socket.emit("getServer", country);
  }, [country]);
  */

  const handleChangeServer = (event) => {
    setServer({ server: event.target.value });
  };

  const handleChangePubkey = (event) => {
    if (
      base64regex.test(event.target.value) &&
      event.target.value.length == 44 &&
      event.target.value.endsWith("=")
    ) {
      setPubkey(event.target.value);
      setValid(true);
      setNewTime("");
      setTime("");
    } else {
      setPubkey(event.target.value);
      setNewTime("");
      setTime("");
      setTimeValid(false);
      setTimeValidOld(false);
      setValid(false);
    }
  };

  //Get wireguard config from Server
  socket
    .off("receiveUpdateSubscription")
    .on("receiveUpdateSubscription", (response) => {
      DEBUG &&
        console.log(`${getDate()} App.js: got msg receiveUpdateSubscription`);
      setSpinner(false);
      // in case the user renewed the subscription and wants to renew it in the same window again
      setTimeValid(false);
      setTimeValidOld(false);

      setPaymentrequest(buildUpdateSubscription(response).join("\n"));
    });

  //Construct the Config File
  const buildUpdateSubscription = (serverResponse) => {
    showInvoiceModal();
    renderConfigModal();
    const configArray = ["New SubscriptionEnd: " + serverResponse.subExpiry];
    return configArray;
  };

  socket
    .off("invoicePaidUpdateSubscription")
    .on("invoicePaidUpdateSubscription", (paymentHash) => {
      DEBUG &&
        console.log(
          `${getDate()} App.js: got msg 'invoicePaidUpdateSubscription': ${paymentHash}, clientPaymentHash: ${clientPaymentHash}`
        );

      if (paymentHash === clientPaymentHash && !isPaid) {
        renderAlert(true);
        isPaid = true;
        setSpinner(true);
      }
    });

  socket
    .removeAllListeners("receiveKeyLookup")
    .on("receiveKeyLookup", (result) => {
      DEBUG && console.log(`${getDate()} receiveKeyLookup(): `);
      DEBUG && console.log("%o", result);

      if (result == null) {
        setPopupMessage(
          "The provided WireGuard pubkey was not found on any server!"
        );
        setTime("");
        setNewTime("");
        setTimeValid(false);
        setTimeValidOld(false);
        renderPopupModal();
        DEBUG && console.log(result);
        setSpinnerQuery(false);
      } else if (result == "not-allowed") {
        setPopupMessage(
          "This server is going to be phased out. Please switch to de3.tunnelsats.com and restart your node (see FAQ page for instructions). Your subscription has already been moved to the new server."
        );
        setTime("");
        setNewTime("");
        setTimeValid(false);
        setTimeValidOld(false);
        renderPopupModal();
        DEBUG && console.log(result);
        setSpinnerQuery(false);
      } else if (typeof result === "object") {
        keyID = result.keyID;

        setTime(result.subscriptionEnd);
        setNewTime(
          getTimeStamp(priceDollar, result.subscriptionEnd).toISOString()
        );
        if (Date.now() < Date.parse(result.subscriptionEnd)) {
          setTimeValid(true);
          setTimeValidOld(true);
        } else {
          setTimeValid(true);
          setTimeValidOld(false);
        }
        // set fetched server domain
        setServer(result.domain);

        updateCountry(result.country);

        setSpinnerQuery(false);
      }
    });

  const handleKeyLookUp = (event) => {
    event.preventDefault();
    // alert('You have submitted the form.')
    //DEBUG && console.log("checkKeyDB emitted", pubkey, server);
    //socket.emit("checkKeyDB", { publicKey: pubkey, serverURL: server });
    DEBUG && console.log("checkKeyDB emitted", pubkey);
    socket.emit("checkKeyDB", { publicKey: pubkey });
    setSpinnerQuery(true);
  };

  const handleSubmit = (event) => {
    event.preventDefault();
    // alert('You have submitted the form.')
    // console.log("Submit Worked", server, pubkey);
  };

  // get renewal invoice
  // { amount, publicKey, keyID, country, priceDollar }
  const getInvoiceRenew = (amount, publicKey, keyID, country, priceDollar) => {
    DEBUG &&
      console.log(
        `${getDate()} App.js: getInvoice(price): ` + priceDollar + `$`
      );
    socket.emit("getInvoiceUpdateSub", {
      amount: Math.round(amount),
      publicKey,
      keyID,
      country,
      priceDollar,
    });
  };

  socket
    .removeAllListeners("lnbitsInvoiceSubscription")
    .on("lnbitsInvoiceSubscription", (invoiceData) => {
      DEBUG && console.log(`${getDate()} App.js: got msg lnbitsInvoice`);
      setPaymentrequest(invoiceData.payment_request);
      clientPaymentHash = invoiceData.payment_hash;
      DEBUG && console.log(clientPaymentHash);
      setSpinner(false);
    });

  return (
    <>
      {/*
      <div>
        <Toast
          show={showA}
          onClose={toggleShowA}
          animation={true}
          style={{
            position: "absolute",
            top: 100,
            right: 0,
          }}
        >           
          <Toast.Header style={{ textAlign: "center" }}>
            <strong className="mr-auto">⚠️ Important Information ⚠️</strong>
          </Toast.Header>
          <Toast.Body
            style={{
              textAlign: "left",
            }}
          >
            <b className="warning">
              Server switch required for EU users on de2.tunnelsats.com!
            </b>
            <br></br>
            <br></br>If you are connected to this VPN, please switch from
            de2.tunnelsats.com to de3.tunnelsats.com. Here is how to easily get
            there:{" "}
            <a
              href="https://Tunnelsats.github.io/tunnelsats/FAQ.html#phasing-out-de2tunnelsatscom---how-to-switch-to-de3tunnelsatscom"
              target="_blank"
              rel="noreferrer"
            >
              migration guide
            </a>
          </Toast.Body>
        </Toast>
      </div>
          */}
      <div>
        <Container>
          {/* Navigation Bar */}
          <Navbar variant="dark" expanded="true">
            <Navbar.Brand>Tunnel⚡️Sats</Navbar.Brand>
            <Nav className="mr-auto">
              {!isRenewSub ? (
                <Nav.Link
                  href="#"
                  onClick={() => {
                    showRenew();
                    updatePrice(REACT_APP_THREE_MONTHS);
                  }}
                >
                  Renew Subscription
                </Nav.Link>
              ) : (
                <Nav.Link
                  href="#"
                  onClick={() => {
                    hideRenew();
                    updatePrice(REACT_APP_THREE_MONTHS);
                  }}
                >
                  Get Subscription
                </Nav.Link>
              )}
              <Nav.Link
                href="https://Tunnelsats.github.io/tunnelsats"
                target="_blank"
                rel="noreferrer"
              >
                Guide
              </Nav.Link>
              <Nav.Link
                href="https://Tunnelsats.github.io/tunnelsats/FAQ.html"
                target="_blank"
                rel="noreferrer"
              >
                FAQ
              </Nav.Link>
              <Nav.Link
                href="https://status.tunnelsats.com"
                target="_blank"
                rel="noreferrer"
              >
                Server Status 🚨
              </Nav.Link>
              {/*
                <Nav.Link>
                <strong>⚡️ Black Friday Special 20% Off ⚡️</strong>
                </Nav.Link>
              */}

              {/*}
                <Nav>
                <Button onClick={() => renderLoginModal()} variant="outline-info">Login</Button>
                <LoginModal show={isLoginModal} handleClose={hideLoginModal} />
                </Nav>
              */}
            </Nav>
            <Nav className="mr-right">
              <Nav.Link
                href={`https://github.com/Tunnelsats/tunnelsats/commit/${commitHash}`}
                target="_blank"
                rel="noreferrer"
              >
                latest commit: {commitHash?.substring(0, 7)}
              </Nav.Link>
            </Nav>
          </Navbar>
        </Container>

        <Popup />

        <Container className="main-middle">
          <Row>
            <Col>
              {/* Logo */}
              <img src={logo} alt="" className="logo" />

              {/* Intro Text */}
              <HeaderInfo stats={nodeStats} />

              {isRenewSub ? (
                <>
                  <hr />
                  <p className="price">Connected to continent:</p>
                  {/* WorldMap */}
                  <WorldMap
                    selected={country}
                    pointerEvents={"none"}
                    Cursor={"not-allowed"}
                  />

                  <hr />

                  <Form onSubmit={(e) => handleSubmit(e)}>
                    {" "}
                    {/* Renew Subscription */}
                    <Form.Group className="updateSubFrom">
                      <InputGroup>
                        <InputGroup.Text>Server</InputGroup.Text>
                        <Form.Control
                          disabled
                          value={server}
                          placeholder="Tunnel⚡️Sats Server"
                          onChange={handleChangeServer}
                          type="text"
                        />
                      </InputGroup>
                      <InputGroup>
                        <InputGroup.Text>WG Pubkey</InputGroup.Text>
                        <Form.Control
                          enabled
                          value={pubkey}
                          placeholder="WireGuard public key (base64 encoded)"
                          isValid={valid}
                          onChange={handleChangePubkey}
                        />
                        <Button
                          variant="secondary"
                          href="https://Tunnelsats.github.io/tunnelsats/FAQ.html#how-can-i-extend-my-subscription"
                          target="_blank"
                        >
                          <IoIosInformationCircleOutline
                            color="white"
                            size={20}
                            title="how to find out your wg pubkey"
                          />
                        </Button>
                      </InputGroup>
                      <Collapse in={valid}>
                        <div id="example-collapse-text">
                          {
                            <div>
                              <InputGroup>
                                <InputGroup.Text>Valid Until:</InputGroup.Text>
                                <Form.Control
                                  disabled
                                  value={timeSubscription}
                                  isValid={timeValidOld}
                                />
                              </InputGroup>
                            </div>
                          }
                        </div>
                      </Collapse>

                      <Collapse in={valid}>
                        <div id="example-collapse-text">
                          {
                            <div>
                              <InputGroup>
                                <InputGroup.Text>
                                  NEW Valid Until:
                                </InputGroup.Text>
                                <Form.Control
                                  disabled
                                  value={newTimeSubscription}
                                  isValid={timeValid}
                                />
                              </InputGroup>
                            </div>
                          }
                        </div>
                      </Collapse>
                    </Form.Group>
                    {showSpinnerQuery ? (
                      <Spinner animation="border" variant="warning" />
                    ) : (
                      <div className="main-buttons">
                        <Button
                          variant="secondary"
                          onClick={handleKeyLookUp}
                          type="submit"
                          disabled={!valid}
                        >
                          Query Key Info
                        </Button>
                      </div>
                    )}
                    <Collapse in={true}>
                      <div id="example-collapse-text">
                        {
                          <div>
                            <RuntimeSelector onClick={runtimeSelect} />
                            {showSpinner ? (
                              <Spinner animation="border" variant="warning" />
                            ) : (
                              <div className="price">
                                <h3>
                                  {discount != 1.0
                                    ? Math.trunc(
                                        Math.round(
                                          priceDollar * satsPerDollar -
                                            priceDollar *
                                              satsPerDollar *
                                              discount
                                        )
                                      )
                                    : Math.trunc(
                                        Math.round(priceDollar * satsPerDollar)
                                      ).toLocaleString()}{" "}
                                  <i class="fak fa-satoshisymbol-solidcirtilt" />
                                </h3>
                              </div>
                            )}
                          </div>
                        }
                      </div>
                    </Collapse>
                    {/* renew update button */}
                    <div className="main-buttons">
                      <Button
                        variant="outline-warning"
                        onClick={() => {
                          getInvoiceRenew(
                            discount != 1.0
                              ? priceDollar * satsPerDollar -
                                  priceDollar * satsPerDollar * discount
                              : priceDollar * satsPerDollar,
                            pubkey,
                            keyID,
                            country,
                            priceDollar
                          );
                          showInvoiceModal();
                          hideConfigModal();
                          updatePaymentrequest();
                          setSpinner(true);
                          isPaid = false;
                        }}
                        type="submit"
                        disabled={!timeValid}
                      >
                        Update Subscription
                      </Button>
                    </div>
                  </Form>

                  {/* renew invoice modal */}
                  <RenewInvoiceModal
                    show={visibleInvoiceModal}
                    showSpinner={showSpinner}
                    isConfigModal={isConfigModal}
                    value={payment_request}
                    showNewInvoice={() => {
                      getInvoiceRenew(
                        discount != 1.0
                          ? priceDollar * satsPerDollar -
                              priceDollar * satsPerDollar * discount
                          : priceDollar * satsPerDollar,
                        pubkey,
                        keyID,
                        country,
                        priceDollar
                      );
                      setSpinner(true);
                    }}
                    handleClose={closeInvoiceModal}
                    expiryDate={getTimeStamp(priceDollar, timeSubscription)}
                    showPaymentAlert={showPaymentSuccessfull}
                  />
                </>
              ) : (
                <>
                  <hr />
                  <p className="price">Select your continent:</p>
                  {/* WorldMap */}
                  <WorldMap
                    selected={country}
                    onSelect={updateCountry}
                    pointerEvents={"all"}
                  />
                  <hr />

                  <Form>
                    {/* else default: WG keys for first subscription */}
                    <Form.Group className="mb-2">
                      <InputGroup>
                        <InputGroup.Text>Private Key</InputGroup.Text>
                        <Form.Control
                          disabled
                          key={keyPair.privateKey}
                          defaultValue={keyPair.privateKey}
                          onChange={(event) => {
                            keyPair.privateKey = event.target.value;
                          }}
                        />
                        <Button
                          onClick={() => {
                            displayNewPair(window.wireguard.generateKeypair);
                          }}
                          variant="secondary"
                        >
                          <IoIosRefresh
                            color="white"
                            size={20}
                            title="renew keys"
                          />
                        </Button>
                      </InputGroup>
                      <InputGroup>
                        <InputGroup.Text>Public Key</InputGroup.Text>
                        <Form.Control
                          disabled
                          key={keyPair.publicKey}
                          defaultValue={keyPair.publicKey}
                          onChange={(event) => {
                            keyPair.publicKey = event.target.value;
                          }}
                        />
                      </InputGroup>
                      <InputGroup>
                        <InputGroup.Text>Preshared Key</InputGroup.Text>
                        <Form.Control
                          disabled
                          key={keyPair.presharedKey}
                          defaultValue={keyPair.presharedKey}
                          onChange={(event) => {
                            keyPair.presharedKey = event.target.value;
                          }}
                        />
                      </InputGroup>
                    </Form.Group>
                  </Form>
                  {
                    <div>
                      <RuntimeSelector onClick={runtimeSelect} />
                      {showSpinner ? (
                        <Spinner animation="border" variant="warning" />
                      ) : (
                        <div className="price">
                          <h3>
                            {discount != 1.0
                              ? Math.trunc(
                                  Math.round(
                                    priceDollar * satsPerDollar -
                                      priceDollar * satsPerDollar * discount
                                  )
                                )
                              : Math.trunc(
                                  Math.round(priceDollar * satsPerDollar)
                                ).toLocaleString()}{" "}
                            <i class="fak fa-satoshisymbol-solidcirtilt" />
                          </h3>
                        </div>
                      )}
                    </div>
                  }

                  {/* Button Generate Invoice */}
                  <div className="main-buttons">
                    <Button
                      onClick={() => {
                        getInvoice(
                          discount != 1.0
                            ? priceDollar * satsPerDollar -
                                priceDollar * satsPerDollar * discount
                            : priceDollar * satsPerDollar,
                          keyPair.publicKey,
                          keyPair.presharedKey,
                          priceDollar,
                          country
                        );
                        showInvoiceModal();
                        hideConfigModal();
                        updatePaymentrequest();
                        setSpinner(true);
                        isPaid = false;
                      }}
                      variant="outline-warning"
                    >
                      Generate Invoice
                    </Button>
                  </div>

                  {/* Open InvoiceModal */}
                  <InvoiceModal
                    show={visibleInvoiceModal}
                    showSpinner={showSpinner}
                    isConfigModal={isConfigModal}
                    value={payment_request}
                    download={() => {
                      download("tunnelsatsv2.conf", payment_request);
                    }}
                    showNewInvoice={() => {
                      getInvoice(
                        discount != 1.0
                          ? priceDollar * satsPerDollar -
                              priceDollar * satsPerDollar * discount
                          : priceDollar * satsPerDollar,
                        keyPair.publicKey,
                        keyPair.presharedKey,
                        priceDollar,
                        country
                      );
                      setSpinner(true);
                    }}
                    handleClose={closeInvoiceModal}
                    emailAddress={emailAddress}
                    expiryDate={getTimeStamp(priceDollar)}
                    sendEmail={(data) =>
                      sendEmail(
                        data,
                        payment_request,
                        getTimeStamp(priceDollar)
                      )
                    }
                    showPaymentAlert={showPaymentSuccessfull}
                  />
                </>
              )}

              {/* Popup Error Message */}
              {isPopupModal ? (
                <Popup
                  show={isPopupModal}
                  title={"⚠️ Error"}
                  errorMessage={popupMessage}
                  handleClose={hidePopupModal}
                />
              ) : null}

              {/* Footer */}
              <div className="footer-text">
                <Row>
                  <Col>
                    <a
                      href="https://twitter.com/TunnelSats"
                      target="_blank"
                      rel="noreferrer"
                    >
                      <span class="icon icon-twitter"></span>
                    </a>
                  </Col>
                  <Col>
                    <a
                      href="https://github.com/Tunnelsats/tunnelsats"
                      target="_blank"
                      rel="noreferrer"
                    >
                      <span class="icon icon-github"></span>
                    </a>
                  </Col>
                  <Col>
                    <a
                      href={REACT_APP_LNBITS_URL}
                      target="_blank"
                      rel="noreferrer"
                    >
                      <span class="icon icon-heart"></span>
                    </a>
                  </Col>
                  <Col>
                    <a
                      href="https://t.me/+NJylaUom-rxjYjU6"
                      target="_blank"
                      rel="noreferrer"
                    >
                      <span class="icon icon-telegram"></span>
                    </a>
                  </Col>
                </Row>
              </div>
            </Col>
          </Row>
        </Container>
      </div>
    </>
  );
}

export default App;
