import React from "react";
import { useState, useEffect } from "react";
import WorldMap from "./WorldMap";
import InvoiceModal from "./InvoiceModal";
import RuntimeSelector from "./RuntimeSelector";
import { Row, Col, Form, InputGroup, Container, Button, Collapse } from "react-bootstrap";
import { getTimeStamp } from "../timefunction.js";
import { PhoneUpdate24Regular as UpdateSubscriptionIcon } from "@fluentui/react-icons";
import HeaderInfo from "./HeaderInfo";
import logo from "../media/tunnelsats_headerlogo3.png";

const getDate = (timestamp) =>
  (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString();

var base64regex =
  /^([0-9a-zA-Z+/]{4})*(([0-9a-zA-Z+/]{2}==)|([0-9a-zA-Z+/]{3}=))?$/;

var clientPaymentHash;
var keyID;
var isPaid = false;
const DEBUG = false;

// Env Variables to have the same code base main and dev
const REACT_APP_LNBITS_URL = process.env.REACT_APP_LNBITS_URL || "";

export default function UpdateSubscription(props) {
  const socket = props.socket;

  // World Map
  const [country, updateCountry] = useState("eu");
  const [server, setServer] = useState("");
  const [pubkey, setPubkey] = useState("");
  const [valid, setValid] = useState(false);
  const [timeValid, setTimeValid] = useState(false);
  const [timeSubscription, setTime] = useState("");
  const [newTimeSubscription, setNewTime] = useState("");
  const [showSpinner, setSpinner] = useState(true);
  const [isConfigModal, showConfigModal] = useState(false);

  const renderConfigModal = () => showConfigModal(true);
  const hideConfigModal = () => showConfigModal(false);

  const [visibleInvoiceModal, setShowInvoiceModal] = useState(false);
  const closeInvoiceModal = () => setShowInvoiceModal(false);
  const showInvoiceModal = () => setShowInvoiceModal(true);

  const [showPaymentSuccessfull, setPaymentAlert] = useState(false);
  const [payment_request, setPaymentrequest] = useState(0);
  const [priceDollar, updatePrice] = useState(0.02);
  const [satsPerDollar, setSatsPerDollar] = useState(
    Math.round(100000000 / 20000)
  );

  //Successful payment alert
  const renderAlert = (show) => {
    setPaymentAlert(show);
    setTimeout(() => setPaymentAlert(false), [2000]);
  };

  //Updates the QR-Code
  const updatePaymentrequest = () => {
    socket.on("lnbitsInvoice", (invoiceData) => {
      console.log(`${getDate()} App.js: got msg lnbitsInvoice`);
      setPaymentrequest(invoiceData.payment_request);
      clientPaymentHash = invoiceData.payment_hash;
      console.log(clientPaymentHash);
      setSpinner(false);
    });
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

  const handleChangeServer = (event) => {
    setServer({ server: event.target.value });
    setNewTime("");
    setTime("");
    setTimeValid(false);
  };

  const handleChangePubkey = (event) => {
    if (
      base64regex.test(event.target.value) &&
      event.target.value.length == 44
    ) {
      setPubkey(event.target.value);
      setValid(true);
      setNewTime("");
      setTime("");
    } else {
      setPubkey(event.target.value);
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

  const handleKeyLookUp = (event) => {
    event.preventDefault();
    // alert('You have submitted the form.')
    console.log("checkKeyDB emitted", server, pubkey);
    socket.emit("checkKeyDB", { serverURL: server, publicKey: pubkey });
  };

  const handleSubmit = (event) => {
    event.preventDefault();
    // alert('You have submitted the form.')
    // console.log("Submit Worked", server, pubkey);
  };

  //Get the invoice
  //   { amount, publicKey, keyID, country, priceDollar }
  const getInvoice = (amount, publicKey, keyID, country, priceDollar) => {
    console.log(`${getDate()} App.js: getInvoice(price): ` + priceDollar + `$`);
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
      console.log(`${getDate()} App.js: got msg lnbitsInvoice`);
      setPaymentrequest(invoiceData.payment_request);
      clientPaymentHash = invoiceData.payment_hash;
      console.log(clientPaymentHash);
      setSpinner(false);
    });

  //Connect to WebSocket Server
  socket.off("connect").on("connect", () => {
    console.log(`${getDate()} App.js: connect`);
    // refresh pricePerDollar on start
    getPrice();
  });

  // get current btc per dollar
  const getPrice = () => {
    socket.emit("getPrice");
  };
  socket.off("receivePrice").on("receivePrice", (price) => {
    console.log(`${getDate()} App.js: server.getPrice(): ` + price);
    setSatsPerDollar(Math.trunc(Math.round(price)));
  });

  socket
    .removeAllListeners("receiveKeyLookup")
    .on("receiveKeyLookup", (result) => {
      console.log(`${getDate()} receiveKeyLookup(): `);
      console.log("%o", result);
      if (typeof result === "object") {
        keyID = result.keyID;

        setTime(result.subscriptionEnd);
        setNewTime(
          getTimeStamp(priceDollar, result.subscriptionEnd).toISOString()
        );
        if (Date.now() < Date.parse(result.subscriptionEnd)) {
          setTimeValid(true);
        } else {
          setTimeValid(false);
        }
      } else {
        console.log(result);
      }
    });

  socket.removeAllListeners("receiveServer").on("receiveServer", (server) => {
    console.log(`${getDate()} App.js: received server: `, server);
    setServer(server);
  });

  // randomize wireguard keys
  useEffect(() => {
    setNewTime("");
    setTime("");
    setTimeValid(false);
    socket.emit("getServer", country);
  }, [country]);

  return (
    <React.Fragment>
      <Container className="main-middle">
        <Row>
          <Col>
            <img src={logo} alt="" />

            <HeaderInfo />

            <WorldMap selected={country} onSelect={updateCountry} />

            <Form onSubmit={(e) => handleSubmit(e)}>
              <Form.Group className="updateSubFrom">
                <InputGroup>
                  <InputGroup.Text>Selected Server</InputGroup.Text>
                  <Form.Control
                    disabled
                    value={server}
                    placeholder="Tunnelsats Server"
                    onChange={handleChangeServer}
                    type="text"
                  />
                </InputGroup>
                <InputGroup>
                  <InputGroup.Text>WG Pubkey</InputGroup.Text>
                  <Form.Control
                    enabled
                    value={pubkey}
                    placeholder="Wireguard Pubkey (base64 encoded)"
                    isValid={valid}
                    onChange={handleChangePubkey}
                  />
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
                            isValid={timeValid}
                            // onChange = { handleChangePubkey}
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
                          <InputGroup.Text>NEW Valid Until:</InputGroup.Text>
                          <Form.Control
                            disabled
                            value={newTimeSubscription}
                            isValid={timeValid}
                            // onChange = { handleChangePubkey}
                          />
                        </InputGroup>
                      </div>
                    }
                  </div>
                </Collapse>
              </Form.Group>
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
              <Collapse in={true}>
                <div id="example-collapse-text">
                  {
                    <div>
                      <RuntimeSelector onClick={runtimeSelect} />
                      <div className="price">
                        <h3>
                          {Math.trunc(
                            Math.round(priceDollar * satsPerDollar)
                          ).toLocaleString()}{" "}
                          <i class="fak fa-satoshisymbol-solidtilt" />
                        </h3>
                      </div>
                    </div>
                  }
                </div>
              </Collapse>
              <div className="main-buttons">
                <Button
                  variant="outline-warning"
                  onClick={() => {
                    getInvoice(
                      priceDollar * satsPerDollar,
                      pubkey,
                      keyID,
                      country,
                      priceDollar
                    );
                    showInvoiceModal();
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

            <InvoiceModal
              show={visibleInvoiceModal}
              showSpinner={showSpinner}
              isConfigModal={isConfigModal}
              value={payment_request}
              showNewInvoice={() => {
                getInvoice(
                  priceDollar * satsPerDollar,
                  pubkey,
                  keyID,
                  country,
                  priceDollar
                );
                setSpinner(true);
              }}
              handleClose={closeInvoiceModal}
              expiryDate={getTimeStamp(priceDollar)}
              showPaymentAlert={showPaymentSuccessfull}
            />

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
                    href="https://github.com/blckbx/tunnelsats"
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
    </React.Fragment>
  );
}
