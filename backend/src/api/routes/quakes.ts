import { Router } from "express";
import { getEvent, listRecentEvents, listRevisions } from "../../db.js";

export const quakesRouter = Router();

quakesRouter.get("/recent", (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const source = typeof req.query.source === "string" ? req.query.source : undefined;
  res.json(listRecentEvents(limit, source));
});

quakesRouter.get("/:id", (req, res) => {
  const event = getEvent(req.params.id);
  if (!event) return res.status(404).json({ error: "not found" });
  res.json({ event, revisions: listRevisions(event.id) });
});
