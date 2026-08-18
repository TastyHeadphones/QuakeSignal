export function createSerialTaskQueue(task: () => Promise<void>): () => Promise<void>;
