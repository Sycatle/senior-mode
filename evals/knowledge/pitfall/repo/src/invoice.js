import { ready } from "./locale.js";

export const totalLabel = (cents) => (ready ? `${cents} EUR` : "");
