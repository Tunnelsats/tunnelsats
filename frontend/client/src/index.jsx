import React from "react";
import { createRoot } from "react-dom/client";  // Add this import

import "./bootstrap/css/bootstrap.min.css";
import "./custombootstrap.css";
import "./index.css";
import App from "./App";

const container = document.getElementById("root");
const root = createRoot(container);  // Create root
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

