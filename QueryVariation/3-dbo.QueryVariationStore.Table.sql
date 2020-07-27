DROP TABLE IF EXISTS [dbo].[QueryVariationStore]
CREATE TABLE [dbo].[QueryVariationStore]
(
	[ReportID]				BIGINT			NOT NULL,
	[QueryID]				BIGINT			NOT NULL,
	[ObjectID]				BIGINT			NOT NULL,
	[SchemaName]			SYSNAME			    NULL,
	[ObjectName]			SYSNAME			    NULL,
	[MeasurementChange]		FLOAT			NOT NULL,
	[MeasurementRecent]		FLOAT			NOT NULL,
	[MeasurementHist]		FLOAT			NOT NULL,
	[ExecutionCountRecent]	BIGINT			NOT NULL,
	[ExecutionCountHist]	BIGINT			NOT NULL,
	[NumPlans]				INT				NOT NULL,
	[QuerySqlText]			VARBINARY(MAX)	    NULL
)
ALTER TABLE [dbo].[QueryVariationStore]
ADD CONSTRAINT [PK_QueryVariationStore] PRIMARY KEY CLUSTERED
(
	 [ReportID] ASC,
	 [QueryID] ASC
)