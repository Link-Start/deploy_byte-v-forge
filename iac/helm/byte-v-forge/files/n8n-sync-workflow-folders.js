'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
let Client;
try {
  ({ Client } = require('pg'));
} catch {
  ({ Client } = require('/usr/local/lib/node_modules/n8n/node_modules/pg'));
}

const workflowRoot = path.resolve(process.argv[2] || process.env.N8N_WORKFLOW_DIR || '/workflows');
const tablePrefix = process.env.DB_TABLE_PREFIX || 'n8n_';
const managedWorkflowIdSQL = "(id like 'gpt-%' or id like 'gopay-%')";
const managedFolderRoots = ['gpt', 'gopay-app'];

function fail(message) {
  console.error(`[n8n-folder-sync] ${message}`);
  process.exit(1);
}

function table(name) {
  const fullName = `${tablePrefix}${name}`;
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(fullName)) {
    fail(`invalid DB table name: ${fullName}`);
  }
  return `"${fullName}"`;
}

function quoteColumn(name) {
  return `"${name}"`;
}

function walk(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (entry.name.startsWith('..')) {
      continue;
    }
    const absolute = path.join(dir, entry.name);
    const stat = entry.isSymbolicLink() ? fs.statSync(absolute) : null;
    if (entry.isDirectory() || (stat && stat.isDirectory())) {
      files.push(...walk(absolute));
      continue;
    }
    if ((entry.isFile() || (stat && stat.isFile())) && entry.name.endsWith('.workflow.json')) {
      files.push(absolute);
    }
  }
  return files.sort();
}

function desiredFolderSegments(file) {
  const relative = path.relative(workflowRoot, file).split(path.sep).join('/');
  const dir = path.posix.dirname(relative);
  if (!dir || dir === '.') return [];
  return dir.split('/').filter(Boolean);
}

function folderKey(parentId, name) {
  return `${parentId || ''}\u0000${name}`;
}

function workflowRecord(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const parsed = JSON.parse(raw);
  if (!parsed.id) {
    throw new Error(`${path.relative(workflowRoot, file)} has no workflow id`);
  }
  return {
    id: parsed.id,
    name: parsed.name || parsed.id,
    file,
    segments: desiredFolderSegments(file),
  };
}

function workflowIds(workflows) {
  return workflows.map((workflow) => workflow.id);
}

function clientFromEnv() {
  return new Client({
    host: process.env.DB_POSTGRESDB_HOST,
    port: Number(process.env.DB_POSTGRESDB_PORT || 5432),
    database: process.env.DB_POSTGRESDB_DATABASE,
    user: process.env.DB_POSTGRESDB_USER,
    password: process.env.DB_POSTGRESDB_PASSWORD,
  });
}

async function resolveProjectId(client) {
  if (process.env.N8N_WORKFLOW_PROJECT_ID) {
    return process.env.N8N_WORKFLOW_PROJECT_ID;
  }
  const result = await client.query(
    `select id, name, type from ${table('project')} order by case when type = 'personal' then 0 else 1 end, ${quoteColumn('createdAt')} asc`,
  );
  if (result.rows.length === 0) {
    throw new Error('no n8n project found');
  }
  if (result.rows.length > 1) {
    console.log(`[n8n-folder-sync] multiple projects found, using ${result.rows[0].id} (${result.rows[0].type})`);
  }
  return result.rows[0].id;
}

async function loadFolders(client, projectId) {
  const result = await client.query(
    `select id, name, ${quoteColumn('parentFolderId')} as "parentFolderId" from ${table('folder')} where ${quoteColumn('projectId')} = $1 order by ${quoteColumn('createdAt')} asc`,
    [projectId],
  );
  const folders = new Map();
  for (const row of result.rows) {
    const key = folderKey(row.parentFolderId || null, row.name);
    if (!folders.has(key)) {
      folders.set(key, row.id);
    }
  }
  return folders;
}

async function ensureFolder(client, folders, projectId, parentId, name) {
  if (name.length > 128) {
    throw new Error(`folder name too long: ${name}`);
  }
  const key = folderKey(parentId, name);
  const existingId = folders.get(key);
  if (existingId) return { id: existingId, created: false };

  const id = crypto.randomUUID();
  await client.query(
    `insert into ${table('folder')} (id, name, ${quoteColumn('parentFolderId')}, ${quoteColumn('projectId')}) values ($1, $2, $3, $4)`,
    [id, name, parentId, projectId],
  );
  folders.set(key, id);
  return { id, created: true };
}

async function deleteRemovedManagedWorkflows(client, desiredWorkflowIds) {
  if (desiredWorkflowIds.length === 0) {
    throw new Error('refuse to delete managed workflows because desired workflow set is empty');
  }
  const stale = await client.query(
    `select id
       from ${table('workflow_entity')}
      where ${managedWorkflowIdSQL}
        and not (id = any($1::text[]))
      order by id`,
    [desiredWorkflowIds],
  );
  const staleIds = stale.rows.map((row) => row.id);
  if (staleIds.length === 0) {
    return 0;
  }

  await client.query(`delete from ${table('workflow_published_version')} where ${quoteColumn('workflowId')} = any($1::text[])`, [staleIds]);
  await client.query(`update ${table('workflow_entity')} set ${quoteColumn('activeVersionId')} = null where id = any($1::text[])`, [staleIds]);
  const deleted = await client.query(`delete from ${table('workflow_entity')} where id = any($1::text[])`, [staleIds]);
  return deleted.rowCount;
}

async function pruneEmptyManagedFolders(client, projectId) {
  let deleted = 0;
  for (const rootName of managedFolderRoots) {
    for (;;) {
      const result = await client.query(
        `with recursive managed as (
            select id, name, ${quoteColumn('parentFolderId')}
              from ${table('folder')}
             where ${quoteColumn('projectId')} = $1
               and ${quoteColumn('parentFolderId')} is null
               and name = $2
            union all
            select child.id, child.name, child.${quoteColumn('parentFolderId')}
              from ${table('folder')} child
              join managed on child.${quoteColumn('parentFolderId')} = managed.id
          )
          delete from ${table('folder')} folder
           where folder.id in (select id from managed)
             and not (folder.${quoteColumn('parentFolderId')} is null and folder.name = $2)
             and not exists (
               select 1
                 from ${table('folder')} child
                where child.${quoteColumn('parentFolderId')} = folder.id
             )
             and not exists (
               select 1
                 from ${table('workflow_entity')} workflow
                where workflow.${quoteColumn('parentFolderId')} = folder.id
             )`,
        [projectId, rootName],
      );
      if (result.rowCount === 0) {
        break;
      }
      deleted += result.rowCount;
    }
  }
  return deleted;
}

async function syncWorkflowFolders() {
  if (!fs.existsSync(workflowRoot)) {
    throw new Error(`workflow root not found: ${workflowRoot}`);
  }

  const files = walk(workflowRoot);
  const workflows = files.map(workflowRecord);
  const client = clientFromEnv();
  await client.connect();

  let createdFolders = 0;
  let assignedWorkflows = 0;
  let deletedRemovedWorkflows = 0;
  let deletedStaleFolders = 0;
  let deletedEmptyFolders = 0;
  try {
    await client.query('begin');
    const projectId = await resolveProjectId(client);
    const folders = await loadFolders(client, projectId);
    deletedRemovedWorkflows = await deleteRemovedManagedWorkflows(client, workflowIds(workflows));

    for (const workflow of workflows) {
      let parentId = null;
      for (const segment of workflow.segments) {
        const folder = await ensureFolder(client, folders, projectId, parentId, segment);
        parentId = folder.id;
        if (folder.created) createdFolders += 1;
      }

      const result = await client.query(
        `update ${table('workflow_entity')}
            set ${quoteColumn('parentFolderId')} = $1,
                ${quoteColumn('updatedAt')} = CURRENT_TIMESTAMP(3)
          where id = $2
            and ${quoteColumn('parentFolderId')} is distinct from $1`,
        [parentId, workflow.id],
      );
      assignedWorkflows += result.rowCount;
    }

    const staleResult = await client.query(
      `with recursive stale as (
          select id
            from ${table('folder')}
           where ${quoteColumn('projectId')} = $1
             and ${quoteColumn('parentFolderId')} is null
             and name like '..%'
          union all
          select child.id
            from ${table('folder')} child
            join stale on child.${quoteColumn('parentFolderId')} = stale.id
        )
        delete from ${table('folder')} folder
         where folder.id in (select id from stale)
           and not exists (
             select 1
               from ${table('workflow_entity')} workflow
              where workflow.${quoteColumn('parentFolderId')} in (select id from stale)
           )`,
      [projectId],
    );
    deletedStaleFolders = staleResult.rowCount;
    deletedEmptyFolders = await pruneEmptyManagedFolders(client, projectId);

    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    await client.end();
  }

  console.log(`[n8n-folder-sync] workflows=${workflows.length} folders_created=${createdFolders} workflows_assigned=${assignedWorkflows} removed_workflows_deleted=${deletedRemovedWorkflows} stale_folders_deleted=${deletedStaleFolders} empty_folders_deleted=${deletedEmptyFolders}`);
}

syncWorkflowFolders().catch((error) => {
  fail(error.message || String(error));
});
