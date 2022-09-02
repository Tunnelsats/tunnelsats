import React from "react";

const Popup = (props) => {
  return (
    <div className="popup-box">
      <div className="box">{props.errorMessage}</div>
    </div>
  );
};

export default Popup;
