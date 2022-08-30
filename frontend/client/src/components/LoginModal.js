import React from "react";
import { Modal, Button, Form, InputGroup } from "react-bootstrap";

const LoginModal = (props) => {
  function makeid(length) {
    var result = "";
    var characters =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var charactersLength = characters.length;
    for (var i = 0; i < length; i++) {
      result += characters.charAt(Math.floor(Math.random() * charactersLength));
    }
    return result;
  }

  const messageToSign = "LN-TunnelSats-" + makeid(20);

  if (!props.show) {
    return null;
  }

  return (
    <div>
      <Modal
        id="faq_modal"
        show={props.show}
        onHide={props.handleClose}
        centered
      >
        <Modal.Header closeButton>
          <Modal.Title>Login</Modal.Title>
        </Modal.Header>
        <Modal.Body>
          <InputGroup className="mb-3">
            <InputGroup.Text>Signing Message</InputGroup.Text>
            <Form.Control
              id="signingMessage"
              type="text"
              readonly
              disabled
              defaultValue={messageToSign}
            />

            <Button
              variant="outline-warning"
              onClick={() => {
                navigator.clipboard.writeText(props.value);
              }}
            >
              Copy
            </Button>
          </InputGroup>

          <Form.Group className="mb-3" controlId="signature">
            <Form.Label>Signature</Form.Label>
            <Form.Control as="textarea" rows={2} />
          </Form.Group>
        </Modal.Body>
        <Modal.Footer>
          <Button variant="outline-warning" onClick={props.handleClose}>
            OK
          </Button>
          <Button variant="outline-secondary" onClick={props.handleClose}>
            Close
          </Button>
        </Modal.Footer>
      </Modal>
    </div>
  );
};

export default LoginModal;
